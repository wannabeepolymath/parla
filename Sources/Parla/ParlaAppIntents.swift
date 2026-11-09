import AppIntents
import Foundation
import ParlaCore

/// Task-scoped injection also covers child tasks, without replacing app ownership.
/// Metadata, constructors and suggestions never resolve the production runtime.
enum AutomationIntentRuntime {
    @TaskLocal static var resolver: (@MainActor @Sendable () -> AutomationRuntime)?
    @MainActor static func resolve() -> AutomationRuntime { resolver?() ?? .shared }
}

enum AutomationIntentError: Error, Equatable, LocalizedError {
    case invalidSession
    case refused(AutomationFailure)
    var errorDescription: String? {
        switch self {
        case .invalidSession: return "This Parla session isn’t valid. Start a new dictation."
        case .refused(let failure): return Self.message(failure)
        }
    }
    private static func message(_ failure: AutomationFailure) -> String {
        switch failure {
        case .disabled: return "Turn on Allow Shortcuts to dictate in Parla."
        case .timeout: return "The dictation took too long."
        case .busy, .waiterLimit: return "Parla is busy. Try again in a moment."
        case .microphoneUnavailable: return "The microphone isn’t available."
        case .modelUnavailable: return "Parla’s speech model isn’t ready."
        case .secure: return "Parla can’t dictate while a password field is active."
        case .staleSession: return "This dictation has ended. Start a new one."
        case .canceled: return "The dictation was canceled."
        case .superseded: return "A newer dictation replaced this one."
        case .unavailable: return "Dictation isn’t available right now."
        case .unsupportedOutputMode: return "Set Dictation output to Cleaned up or Original text in Parla."
        case .empty: return "No speech was recognized."
        case .minimumDuration: return "The dictation was too short."
        case .resultLimit: return "The dictation was too long."
        case .shuttingDown: return "Parla is quitting."
        }
    }
}

/// Handles are bounded process/session identities, not secrets or authorization.
/// Exact canonical spelling prevents permissive UUID parsing or extra payloads.
enum AutomationIntentID {
    static func control(_ id: AutomationSessionID) -> String { encode("parla-control", id.process, id.id) }
    static func result(process: UUID, operation: UUID) -> String { encode("parla-result", process, operation) }
    private static func encode(_ kind: String, _ process: UUID, _ id: UUID) -> String {
        "\(kind):1:\(process.uuidString.lowercased()):\(id.uuidString.lowercased())"
    }
    static func parse(_ value: String, kind: String) -> AutomationSessionID? {
        guard value.utf8.count == kind.utf8.count + 76 else { return nil }
        let fields = value.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 4, fields[0] == kind, fields[1] == "1",
              let process = UUID(uuidString: String(fields[2])), let id = UUID(uuidString: String(fields[3])),
              encode(kind, process, id) == value else { return nil }
        return AutomationSessionID(process: process, id: id)
    }
    static func controlSession(_ value: String) throws -> AutomationSessionID {
        guard let id = parse(value, kind: "parla-control") else { throw AutomationIntentError.invalidSession }
        return id
    }
}

struct ParlaAutomationResultEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Parla Result"
    static var defaultQuery = ParlaAutomationResultQuery()
    let id: String
    @Property(title: "Text") var text: String
    @Property(title: "Outcome") var outcome: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Parla Result") }

    init(process: UUID, value: DictationResultStore.Value) {
        id = AutomationIntentID.result(process: process, operation: value.operationID)
        text = value.text
        outcome = value.outcome.rawValue
    }
}

struct ParlaAutomationResultQuery: EntityQuery {
    func suggestedEntities() async throws -> [ParlaAutomationResultEntity] { [] }
    @MainActor func entities(for identifiers: [String]) async throws -> [ParlaAutomationResultEntity] {
        // No enumeration, no history and no service resolution for empty/invalid input.
        let requested = identifiers.compactMap { AutomationIntentID.parse($0, kind: "parla-result") }
        guard !requested.isEmpty, !Task.isCancelled else { return [] }
        let runtime = AutomationIntentRuntime.resolve()
        guard requested.contains(where: { $0.process == runtime.broker.process }),
              case .success(let value) = runtime.broker.getLast(),
              requested.contains(AutomationSessionID(process: runtime.broker.process, id: value.operationID)) else { return [] }
        return [ParlaAutomationResultEntity(process: runtime.broker.process, value: value)]
    }
}

struct StartParlaDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Parla Dictation"
    static var description = IntentDescription("Starts a dictation. Turn on Allow Shortcuts to dictate in Parla first.")
    static var openAppWhenRun = true
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let broker = AutomationIntentRuntime.resolve().broker
        let started = try await broker.startOrJoin().mapError(AutomationIntentError.refused).get()
        if let failure = broker.validateStart(started.sessionID) { throw AutomationIntentError.refused(failure) }
        return .result(value: AutomationIntentID.control(started.sessionID))
    }
}

struct StopParlaDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Parla Dictation"
    static var description = IntentDescription("Stops the dictation and returns its text. Nothing is pasted.")
    static var openAppWhenRun = true
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Session", description: "The session from Start Parla Dictation.") var controlSession: String
    init() {}
    init(controlSession: String) { self.controlSession = controlSession }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<ParlaAutomationResultEntity> {
        let session = try AutomationIntentID.controlSession(controlSession)
        let broker = AutomationIntentRuntime.resolve().broker
        let value = try await broker.stop(sessionID: session).mapError(AutomationIntentError.refused).get()
        // Revalidate after the async call and return without another suspension.
        let current = try broker.getLast().mapError(AutomationIntentError.refused).get()
        guard current == value else { throw AutomationIntentError.refused(.unavailable) }
        return .result(value: ParlaAutomationResultEntity(process: broker.process, value: current))
    }
}

struct CancelParlaDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "Cancel Parla Dictation"
    static var description = IntentDescription("Cancels the dictation without returning any text.")
    static var openAppWhenRun = true
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Session", description: "The session from Start Parla Dictation.") var controlSession: String
    init() {}
    init(controlSession: String) { self.controlSession = controlSession }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let session = try AutomationIntentID.controlSession(controlSession)
        if Task.isCancelled { throw AutomationIntentError.refused(.canceled) }
        let status = try AutomationIntentRuntime.resolve().broker.cancel(sessionID: session)
            .mapError(AutomationIntentError.refused).get()
        switch status {
        case .canceled: return .result(value: "Canceled")
        case .alreadyCanceled: return .result(value: "Already canceled")
        case .alreadyCompleted: return .result(value: "Already completed")
        }
    }
}

struct GetLastParlaResultIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Last Parla Result"
    static var description = IntentDescription("Returns the text of the last Shortcuts dictation, if it’s still available.")
    static var openAppWhenRun = true
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<ParlaAutomationResultEntity> {
        let broker = AutomationIntentRuntime.resolve().broker
        let value = try broker.getLast().mapError(AutomationIntentError.refused).get()
        return .result(value: ParlaAutomationResultEntity(process: broker.process, value: value))
    }
}

struct ParlaAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartParlaDictationIntent(), phrases: ["Start dictation with \(.applicationName)"],
                    shortTitle: "Start Dictation", systemImageName: "mic")
        AppShortcut(intent: StopParlaDictationIntent(), phrases: ["Stop dictation with \(.applicationName)"],
                    shortTitle: "Stop Dictation", systemImageName: "stop.circle")
        AppShortcut(intent: CancelParlaDictationIntent(), phrases: ["Cancel dictation with \(.applicationName)"],
                    shortTitle: "Cancel Dictation", systemImageName: "xmark.circle")
        AppShortcut(intent: GetLastParlaResultIntent(), phrases: ["Get last result from \(.applicationName)"],
                    shortTitle: "Get Last Result", systemImageName: "text.alignleft")
    }
}
