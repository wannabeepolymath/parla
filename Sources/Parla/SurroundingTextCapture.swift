import Foundation
import ParlaCore

/// An issued read remains owned until value returns, even after cancel/deadline.
/// No queue, detached task, native API or default filesystem/permission probe.
struct SurroundingTextRead {
    let value: () async throws -> SurroundingTextResponse
    let cancel: () -> Void
    init(value: @escaping () async throws -> SurroundingTextResponse, cancel: @escaping () -> Void = {}) {
        self.value = value; self.cancel = cancel
    }
}
struct SurroundingTextPort {
    let proof: @MainActor () -> SurroundingTextField?
    let issue: @MainActor (SurroundingTextField, NSRange, TimeInterval) throws -> SurroundingTextRead
    // Native qualification is EMPTY in code. No settings flag can activate AX.
    // A future adapter must establish actor, timeout and range semantics in B08.
    static let nativeQualifications: Set<String> = []
    static let unsupported = SurroundingTextPort(proof: { nil }, issue: { _, _, _ in throw SurroundingTextFailure.refused })
}

/// Shipping post-ASR composition. The Pipeline calls this lazily only in its
/// ordinary provider branch. Fakes replace only the qualified field/HTTP bottoms.
enum SurroundingTextCapture {
    static func clean(session: DictationSession.Session, landed: DictationSession.Landed,
        transcript: String, context: CleanupContext, store: SettingsStore, environment: [String: String],
        port: SurroundingTextPort, driver: @escaping HistoryRetryHTTP.Driver,
        now: @escaping () -> TimeInterval, sleep: ((TimeInterval) async throws -> Void)?,
        disarmLearning: @escaping @MainActor () -> Void) async throws -> String? {
        guard let grant = session.surroundingTextGrant, session.delivery == .keyboard,
              session.mode == .dictation, !session.live, landed.landing == .pending,
              session.effectiveSettings.outputMode == .cleanup, session.effectiveSettings.cleanupEnabled,
              !session.effectiveSettings.usesAppleIntelligence, session.effectiveSettings.cleanupFailover == nil,
              session.output?.profile?.id == grant.policy.profileID, landed.bundleID == grant.policy.target,
              !TextRules.isBrowser(bundleID: landed.bundleID),
              (try? CleanupChainIdentity.primary(session.effectiveSettings)) == grant.policy.primary,
              !session.operation.shouldAbort else { return nil }
        let run = session.surroundingTextRun
        // Pre-issuance unsupported/ineligible is category-only, including this build's
        // default native port. This proof port must return nontext metadata only.
        let field = await MainActor.run { port.proof() }
        guard let field, field.eligible, field.app == grant.policy.target else { return nil }
        do { try store.withSurroundingTextGrant(grant, operationID: session.operation.id) {} }
        catch { return nil }
        let policy = HistoryRetryExecutionPolicy(planned: 1, budget: 15, now: now,
            sleep: sleep ?? { seconds in try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) })
        guard let unsubscribe = try? store.subscribeSurroundingText(grant, operationID: session.operation.id, cancel: { [weak run, weak policy] in
            run?.revoke(); policy?.stop(.canceled)
        }) else { return nil }
        var handedOff = false
        defer { if !handedOff { unsubscribe() } }
        func check() throws {
            try policy.check(); try run.check()
            guard !session.operation.shouldAbort else { throw SurroundingTextFailure.refused }
            try store.withSurroundingTextGrant(grant, operationID: session.operation.id) {}
        }
        func proof() async throws {
            try await MainActor.run {
                guard port.proof() == field else { run.revoke(); throw SurroundingTextFailure.refused }
                try check()
            }
        }
        do {
            let result: String? = try await policy.joined {
                let started = now()
                let read = try await MainActor.run {
                    try store.withSurroundingTextGrant(grant, operationID: session.operation.id) {
                        try policy.check(); try run.check()
                        guard !session.operation.shouldAbort, port.proof() == field else {
                            run.revoke(); throw SurroundingTextFailure.refused
                        }
                        // No await or actor hop while under store lock. Issuance is
                        // synchronous on main; a future element timeout must be <=1s.
                        run.readIssued(); disarmLearning()
                        return try port.issue(field, field.request, 1)
                    }
                }
                policy.installCancellation { read.cancel() }
                let response = try await withTaskCancellationHandler(operation: { try await read.value() }, onCancel: { read.cancel() })
                policy.installCancellation {} // The read has actually exited.
                try check(); try await proof()
                guard now() < started + 1 else { throw SurroundingTextFailure.refused }
                guard let prefix = try response.prefix(expected: field) else { return nil }
                // Prefix is ephemeral. Reserve app-owned read/retained/prompt material;
                // serializers/HTTP maintain their existing body/response ledger.
                try policy.reserve(512 * 2 + 1024 + 16 * 1024 * 4)
                // Bound borrowed inputs before interpolation/JSON escaping. Actual
                // aggregate prompt bytes are checked below, without truncation.
                var remaining = 16 * 1024
                func charge(_ text: String) throws {
                    let size = text.utf8.count
                    guard size <= remaining else { throw SurroundingTextFailure.refused }
                    remaining -= size
                }
                try charge(transcript)
                for word in context.dictionary { try charge(word) }
                for (trigger, expansion) in context.snippets { try charge(trigger); try charge(expansion) }
                var requestContext = context; requestContext.precedingText = prefix
                guard PromptBuilder.system(context: requestContext).utf8.count + PromptBuilder.user(transcript: transcript, context: requestContext).utf8.count <= 16 * 1024 else { throw SurroundingTextFailure.refused }
                try check()
                let access = try store.withSurroundingTextGrant(grant, operationID: session.operation.id) {
                    try policy.check(); try run.check()
                    return try prepareCleanupAccess(settings: session.effectiveSettings, env: environment, credentials: store.credentials)
                }
                // Main proof after all credential I/O, before client construction.
                // Construct/resume admissions below perform NO main/AX/actor work.
                try await proof(); try check()
                run.willSend()
                let construct = { try makeSurroundingTextCleanupClient(settings: session.effectiveSettings,
                    access: access, grant: grant, operationID: session.operation.id, store: store,
                    run: run, policy: policy, driver: driver, shouldContinue: { !session.operation.shouldAbort }) }
                let client = try session.operation.diagnostics.map { diagnostic in
                    try diagnostic.makeProvider(settings: session.effectiveSettings, factory: construct)
                } ?? construct()
                let result = try await client.clean(transcript: transcript, context: requestContext)
                try check(); try await proof(); try check()
                return result
            }
            if result != nil {
                // Watchdog and actual HTTP work have exited before final acceptance.
                try await proof(); try check()
                run.acceptedOutput(); run.holdAuthority(unsubscribe); handedOff = true
            }
            return result
        } catch {
            if !run.participated { return nil } // Still pre-issuance category eligibility.
            run.revoke()
            // Error descriptions, provider model, key, prompt and response body never
            // reach Pipeline's detailed/public error paths. No category resend.
            throw SurroundingTextFailure.refused
        }
    }
}
