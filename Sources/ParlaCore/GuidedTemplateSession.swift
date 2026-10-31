import Foundation

/// RAM-only state. The application owner alone supplies recorder/recognition effects.
public struct GuidedTemplateSession: Sendable {
    public enum Disposition: Equatable, Sendable { case accepted(String), skipped }
    public struct Take: Equatable, Sendable {
        public let session: UUID, template: UUID, revision: UUID, field: UUID, fieldRevision: UUID, attempt: UUID, capture: UUID
    }
    public struct Preview: Equatable, Sendable { public let id: UUID; public let body: String }
    public struct Completion: Equatable, Sendable { public let id: UUID; public let date: Date; public let body: String }
    public let id = UUID()
    public let definition: GuidedTemplateDefinition
    public let program: GuidedTemplateProgram
    public let began: TimeInterval
    public private(set) var index = 0
    public private(set) var starts = 0
    public private(set) var fieldRevision = UUID()
    public private(set) var accepted: [UUID: Disposition] = [:]
    public private(set) var take: Take?
    public private(set) var candidate: String?
    public private(set) var preview: Preview?
    public private(set) var completion: Completion?
    public private(set) var saved = false
    public var field: GuidedTemplateField { definition.fields[index] }
    public var allAnswered: Bool { accepted.count == definition.fields.count }
    public init(definition: GuidedTemplateDefinition, now: TimeInterval) throws {
        self.definition = definition; program = try definition.compiled(); began = now
    }
    public func isExpired(now: TimeInterval) -> Bool { now < began || now - began >= 1_200 }
    public mutating func start(now: TimeInterval) throws -> Take {
        guard take == nil, completion == nil, !isExpired(now: now), starts < 60 else { throw GuidedTemplateFailure("Form expired, busy or recording limit reached.") }
        preview = nil; candidate = nil; starts += 1
        let value = Take(session: id, template: definition.id, revision: definition.revision, field: field.id,
                         fieldRevision: fieldRevision, attempt: UUID(), capture: UUID())
        take = value; return value
    }
    public mutating func settle(_ value: Take, text: String?) {
        guard take == value else { return }
        take = nil
        candidate = text.flatMap { GuidedTemplateDefinition.text($0, limit: 8_192) ? $0 : nil }
    }
    public mutating func editCandidate(_ text: String) throws {
        guard take == nil, completion == nil, candidate != nil, text.utf8.count <= 8_192 else { throw GuidedTemplateFailure("Candidate unavailable or too large.") }
        candidate = text
    }
    public mutating func accept() throws {
        guard take == nil, completion == nil, let candidate, GuidedTemplateDefinition.text(candidate, limit: 8_192) else { throw GuidedTemplateFailure("Review a nonempty candidate first.") }
        var next = accepted; next[field.id] = .accepted(candidate)
        let count = next.values.reduce(0) { count, value in if case .accepted(let text) = value { return count + text.utf8.count }; return count }
        guard count <= 98_304 else { throw GuidedTemplateFailure("Accepted fields exceed 98,304 bytes.") }
        accepted = next; advance()
    }
    public mutating func skip() throws {
        guard take == nil, completion == nil, !field.required else { throw GuidedTemplateFailure("Required fields cannot be skipped.") }
        accepted[field.id] = .skipped; advance()
    }
    private mutating func advance() {
        candidate = nil; preview = nil; fieldRevision = UUID()
        if index + 1 < definition.fields.count { index += 1 }
    }
    public mutating func back() {
        guard take == nil, completion == nil else { return }
        index = max(0, index - 1); candidate = nil; preview = nil; fieldRevision = UUID()
    }
    public mutating func discardCandidate() { guard take == nil, completion == nil else { return }; candidate = nil; preview = nil }
    public mutating func review() throws {
        guard take == nil, completion == nil, allAnswered else { throw GuidedTemplateFailure("Accept or skip each field before full review.") }
        let values = accepted.mapValues { value in if case .accepted(let text) = value { return text }; return "" }
        preview = Preview(id: UUID(), body: try program.render(values))
    }
    public mutating func approve(_ review: UUID, date: Date) {
        guard take == nil, completion == nil, let preview, preview.id == review else { return }
        completion = Completion(id: UUID(), date: date, body: preview.body)
    }
    public mutating func markSaved(_ result: UUID) { if completion?.id == result { saved = true } }
}
