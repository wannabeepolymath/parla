import Foundation

enum SharedResult {
    // 256 KiB accommodates long dictations while bounding the keyboard's decode and review memory.
    static let maximumUTF8Bytes = 256 * 1024
    // JSON can escape each input byte as six ASCII bytes; leave room for session metadata.
    static let maximumEnvelopeBytes = maximumUTF8Bytes * 6 + 16 * 1024
    static let copyFromApp = "This result is too large for the keyboard. Open Parla and copy from the app."
    static func limit(_ session: inout DictationSession) {
        if let result = session.result, result.utf8.count > maximumUTF8Bytes {
            session.result = nil
            session.error = [session.error, copyFromApp].compactMap { $0 }.joined(separator: " ")
        }
    }
}

enum SessionPhase: String, Codable { case requested, recording, processing, completed, failed, cancelled, consumed }
enum SessionCommand: String, Codable { case none, stop, cancel }
enum DeliveryDestination: String, Codable { case app, keyboard, clipboard, note }
struct DictationSession: Identifiable, Codable, Equatable {
    var id = UUID()
    var generation = UUID()
    var phase: SessionPhase = .requested
    var command: SessionCommand = .none
    var destination: DeliveryDestination = .app
    var documentID: UUID?
    var keyboardInstance: UUID?
    var created = Date()
    var expires = Date().addingTimeInterval(120)
    var result: String?
    var error: String?
    var acknowledgedAt: Date?
    var active: Bool { [.requested, .recording, .processing].contains(phase) }
    mutating func expire(now: Date) {
        if now >= expires { phase = .cancelled; result = nil; error = nil; command = .none }
    }
}
struct SessionEnvelope: Codable {
    var schema = 1
    var session: DictationSession?
    var feedback = true
}
enum DeliveryGuard {
    // Explicit review is always required; document identity alone does not prove cursor identity.
    static func canConsume(_ session: DictationSession, request: UUID, instance: UUID, document: UUID,
                           sensitive: Bool, explicitlyReviewed: Bool, now: Date) -> Bool {
        session.id == request && session.keyboardInstance == instance && session.documentID == document &&
        session.phase == .completed && session.result.map { $0.utf8.count <= SharedResult.maximumUTF8Bytes } == true && session.acknowledgedAt == nil &&
        now < session.expires && !sensitive && explicitlyReviewed
    }
}
struct SessionStore {
    let file: ProtectedFile<SessionEnvelope>
    init() throws { file = try SharedContainer.file() }
    init(file: ProtectedFile<SessionEnvelope>) { self.file = file }
    func read(now: Date = Date()) throws -> DictationSession? {
        try file.transaction { state in
            guard state.schema == 1 else { throw ParlaError.message("Parla and its keyboard need the same app version. Update Parla and try again.") }
            state.session?.expire(now: now)
            if var session = state.session { SharedResult.limit(&session); state.session = session }
            return state.session
        }
    }
    func request(destination: DeliveryDestination, document: UUID? = nil, instance: UUID? = nil) throws -> DictationSession {
        try file.transaction { state in
            state.session?.expire(now: Date())
            guard state.session?.active != true else { throw ParlaError.message("Another dictation is active. Finish or cancel it first.") }
            var session = DictationSession(); session.destination = destination
            session.documentID = document; session.keyboardInstance = instance
            state.session = session; return session
        }
    }
    @discardableResult func update(id: UUID, generation: UUID, _ body: (inout DictationSession) throws -> Void) throws -> Bool {
        try updateSnapshot(id: id, generation: generation, body) != nil
    }
    // Return the owned transition under the same lock; a later read may belong to another request.
    func updateSnapshot(id: UUID, generation: UUID, _ body: (inout DictationSession) throws -> Void) throws -> DictationSession? {
        try file.transaction { state in
            state.session?.expire(now: Date())
            guard var session = state.session, session.id == id, session.generation == generation,
                  ![.cancelled, .consumed].contains(session.phase) else { return nil }
            try body(&session); SharedResult.limit(&session); state.session = session; return session
        }
    }
    /// Save failures do not invalidate recognized text. Retain locally before the shared write can fail.
    func complete(_ request: DictationSession, final: String, failure: String?, note: String?,
                  save: () throws -> Void, retain: (DictationSession) -> Void) throws -> DictationSession? {
        try updateSnapshot(id: request.id, generation: request.generation) { current in
            try Task.checkCancellation()
            guard current.phase == .processing, current.command != .cancel else { throw CancellationError() }
            var warning: String?
            do { try save() }
            catch is CancellationError { throw CancellationError() }
            catch { warning = "Couldn't save to history. Your text is still available; copy it before leaving Parla." }
            try Task.checkCancellation()
            current.phase = failure == nil ? .completed : .failed
            current.error = [note, warning].compactMap { $0 }.joined(separator: " ")
            if current.error?.isEmpty == true { current.error = nil }
            current.result = final.isEmpty ? nil : final; current.command = .none
            current.expires = Date().addingTimeInterval(120)
            SharedResult.limit(&current)
            retain(current)
        }
    }
    func command(_ command: SessionCommand, id: UUID, generation: UUID) throws {
        try update(id: id, generation: generation) { session in
            if command == .cancel {
                session.phase = .cancelled; session.result = nil; session.error = nil; session.command = .cancel; return
            }
            guard session.active else { return }
            session.command = command
        }
    }
    func consume(request: UUID, instance: UUID, document: UUID, sensitive: Bool, reviewed: Bool) throws -> String? {
        try file.transaction { state in
            guard var session = state.session,
                  DeliveryGuard.canConsume(session, request: request, instance: instance, document: document,
                                           sensitive: sensitive, explicitlyReviewed: reviewed, now: Date()) else { return nil }
            let text = session.result
            // Persist spent capability BEFORE touching textDocumentProxy. Crash here loses insertion safely.
            session.result = nil; session.phase = .consumed; session.acknowledgedAt = Date()
            state.session = session; return text
        }
    }
}
