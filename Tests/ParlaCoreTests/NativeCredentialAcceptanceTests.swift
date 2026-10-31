// Isolated credential checks. Native execution requires explicit opt-in,
// passing fake guards and independent review; normal CI never calls Security.
import XCTest
import Foundation
import Security
import LocalAuthentication
import Darwin
@testable import ParlaCore

final class NativeCredentialAcceptanceTests: XCTestCase {
    func testFakePositiveSequenceHasExactCountsAndStaleReference() throws {
        let f = try Fixture()
        try f.guardrail.run(f.backend)
        XCTAssertEqual(f.guardrail.counts, Counts(copy: 5, add: 1, update: 1, delete: 1))
        XCTAssertEqual(f.fake.counts, f.guardrail.counts)
        XCTAssertEqual(f.fake.dataReads, 3)
        XCTAssertEqual(f.fake.removals, 1)
        XCTAssertEqual(f.guardrail.closeStatus, .complete)
        XCTAssertTrue(f.fake.safeQueries && f.fake.onlyOwnedReferences)
        XCTAssertTrue(f.fake.freshContexts && f.guardrail.replacedInteractiveDelete)
        XCTAssertTrue(f.fake.staleReadUsedReference)
        let counts = f.guardrail.counts
        f.guardrail.cleanupIfEligible(f.backend)
        XCTAssertEqual(f.guardrail.counts, counts)
    }

    func testFakeNamespaceAndPhaseRefusalsNeverForward() throws {
        let changes: [(inout [String: Any]) -> Void] = [
            { $0[kSecAttrService as String] = "wrong-service" },
            { $0[kSecAttrAccount as String] = "wrong-account" },
            { $0[kSecClass as String] = kSecClassInternetPassword },
            { $0[kSecAttrSynchronizable as String] = true },
            { $0[kSecMatchLimit as String] = kSecMatchLimitAll },
            { $0[kSecReturnData as String] = true }
        ]
        for change in changes {
            let f = try Fixture()
            let backend = SecurityCredentialBackend(functions: rewrite(f.guardrail.functions, change))
            XCTAssertEqual(backend.status(f.scope), .error)
            XCTAssertEqual(f.fake.counts, Counts())
            XCTAssertFalse(f.guardrail.owned)
        }
        // Matching value bytes cannot grant ownership or authorize another phase.
        for operation in 0..<3 {
            let f = try Fixture()
            switch operation {
            case 0: _ = f.backend.read(f.scope, interactive: false)
            case 1: _ = f.backend.update(f.guardrail.first, scope: f.scope, interactive: false)
            default: _ = f.backend.delete(f.scope)
            }
            XCTAssertEqual(f.fake.counts, Counts())
            XCTAssertFalse(f.guardrail.owned)
            f.guardrail.cleanupIfEligible(f.backend)
            XCTAssertEqual(f.fake.counts, Counts())
        }
        // Ownership alone also cannot skip the first verification read.
        for operation in 0..<3 {
            let f = try Fixture()
            try f.own()
            let before = f.fake.counts
            switch operation {
            case 0: _ = f.backend.update(f.guardrail.second, scope: f.scope, interactive: false)
            case 1: _ = f.backend.delete(f.scope)
            default: _ = f.backend.status(f.scope)
            }
            XCTAssertEqual(f.fake.counts, before)
        }
    }

    func testFakeWrongReferenceCannotReachReadUpdateOrDelete() throws {
        for operation in 0..<3 {
            let f = try Fixture()
            try f.own()
            if operation != 0 {
                try require(matches(f.backend.read(f.scope, interactive: false), f.guardrail.first))
            }
            if operation == 2 {
                try require(succeeded(f.backend.update(f.guardrail.second, scope: f.scope, interactive: false)))
                try require(matches(f.backend.read(f.scope, interactive: false), f.guardrail.second))
            }
            let before = f.fake.counts
            let backend = SecurityCredentialBackend(functions: rewrite(f.guardrail.functions) {
                $0[kSecValuePersistentRef as String] = Data("unowned-reference".utf8)
            })
            switch operation {
            case 0: _ = backend.read(f.scope, interactive: false)
            case 1: _ = backend.update(f.guardrail.second, scope: f.scope, interactive: false)
            default: _ = backend.delete(f.scope)
            }
            XCTAssertEqual(f.fake.counts, before)
            XCTAssertTrue(f.guardrail.owned)
        }
    }

    func testFakeCollisionDenialCancellationAndErrorStopBeforeAdd() throws {
        for status in [errSecSuccess, errSecInteractionNotAllowed, errSecAuthFailed,
                       errSecNotAvailable, errSecUserCanceled, errSecParam, errSecInternalComponent] {
            let f = try Fixture()
            f.fake.preflight = status
            XCTAssertThrowsError(try f.guardrail.run(f.backend))
            XCTAssertEqual(f.fake.counts, Counts(copy: 1))
            XCTAssertEqual(f.fake.dataReads, 0)
            XCTAssertFalse(f.guardrail.owned || f.guardrail.deletionAttempted)
            XCTAssertEqual(f.guardrail.closeStatus, .refusedUnowned)
        }
    }

    func testFakeDuplicateAndFailedAddGrantNoOwnershipOrCleanup() throws {
        for status in [errSecDuplicateItem, errSecInteractionNotAllowed, errSecUserCanceled,
                       errSecParam, errSecInternalComponent, errSecItemNotFound] {
            let f = try Fixture()
            f.fake.addStatus = status
            XCTAssertThrowsError(try f.guardrail.run(f.backend))
            XCTAssertEqual(f.fake.counts, Counts(copy: 1, add: 1))
            XCTAssertEqual(f.fake.dataReads, 0)
            XCTAssertFalse(f.guardrail.owned || f.guardrail.deletionAttempted)
            f.guardrail.cleanupIfEligible(f.backend)
            XCTAssertEqual(f.fake.counts, Counts(copy: 1, add: 1))
        }
    }

    func testFakeAddWithoutUsableReferenceRecordsPossibleResidue() throws {
        let references: [CFTypeRef?] = [nil, Data() as CFData, "wrong-type" as CFString]
        for reference in references {
            let f = try Fixture()
            f.fake.addReference = reference
            XCTAssertThrowsError(try f.guardrail.run(f.backend))
            XCTAssertEqual(f.fake.counts, Counts(copy: 1, add: 1))
            XCTAssertTrue(f.guardrail.addSucceeded)
            XCTAssertFalse(f.guardrail.owned || f.guardrail.deletionAttempted)
            XCTAssertEqual(f.guardrail.closeStatus, .residualWithoutReference)
        }
    }

    func testFakeOrdinaryMismatchCleansOwnedReferenceOnlyOnce() throws {
        let f = try Fixture()
        f.fake.mismatch = true
        XCTAssertThrowsError(try f.guardrail.run(f.backend))
        XCTAssertEqual(f.fake.counts, Counts(copy: 4, add: 1, delete: 1))
        XCTAssertEqual(f.fake.removals, 1)
        XCTAssertEqual(f.guardrail.closeStatus, .cleanupComplete)
        XCTAssertTrue(f.fake.onlyOwnedReferences && f.fake.staleReadUsedReference)
        let before = f.fake.counts
        f.guardrail.cleanupIfEligible(f.backend)
        _ = f.backend.delete(f.scope)
        XCTAssertEqual(f.fake.counts, before)
    }

    func testFakeFailedDeletionIsNeverRetried() throws {
        for status in [errSecInteractionNotAllowed, errSecUserCanceled, errSecParam,
                       errSecInternalComponent, errSecItemNotFound] {
            let f = try Fixture()
            f.fake.deleteStatus = status
            XCTAssertThrowsError(try f.guardrail.run(f.backend))
            XCTAssertEqual(f.fake.counts, Counts(copy: 3, add: 1, update: 1, delete: 1))
            XCTAssertEqual(f.fake.removals, 0)
            XCTAssertTrue(f.guardrail.deletionAttempted)
            XCTAssertEqual(f.guardrail.closeStatus, .residualOwned)
            let before = f.fake.counts
            f.guardrail.cleanupIfEligible(f.backend)
            _ = f.backend.delete(f.scope)
            XCTAssertEqual(f.fake.counts, before)
        }
    }

    func testFakeFailedCleanupDeleteIsNeverRetried() throws {
        let f = try Fixture()
        f.fake.mismatch = true
        f.fake.deleteStatus = errSecParam
        XCTAssertThrowsError(try f.guardrail.run(f.backend))
        XCTAssertEqual(f.fake.counts, Counts(copy: 2, add: 1, delete: 1))
        XCTAssertEqual(f.fake.removals, 0)
        XCTAssertEqual(f.guardrail.closeStatus, .residualOwned)
        let before = f.fake.counts
        f.guardrail.cleanupIfEligible(f.backend)
        _ = f.backend.delete(f.scope)
        XCTAssertEqual(f.fake.counts, before)
    }

    func testFakePostDeleteCollisionOrDenialNeverReadsOrRemovesAnotherItem() throws {
        for status in [errSecSuccess, errSecInteractionNotAllowed, errSecParam] {
            let f = try Fixture()
            f.fake.postflight = status
            XCTAssertThrowsError(try f.guardrail.run(f.backend))
            XCTAssertEqual(f.fake.counts, Counts(copy: 5, add: 1, update: 1, delete: 1))
            XCTAssertEqual(f.fake.dataReads, 3)
            XCTAssertEqual(f.fake.removals, 1)
            XCTAssertEqual(f.guardrail.closeStatus, .removedUnconfirmed)
            XCTAssertTrue(f.fake.staleReadUsedReference)
            let before = f.fake.counts
            f.guardrail.cleanupIfEligible(f.backend)
            XCTAssertEqual(f.fake.counts, before)
        }
    }

    func testFakeDeniedUnknownOrMalformedOwnedReadStopsWithResidual() throws {
        for status in [errSecInteractionNotAllowed, errSecUserCanceled, errSecParam,
                       errSecInternalComponent, errSecSuccess] {
            let f = try Fixture()
            f.fake.readStatus = status
            f.fake.malformedRead = status == errSecSuccess
            XCTAssertThrowsError(try f.guardrail.run(f.backend))
            XCTAssertEqual(f.fake.counts, Counts(copy: 2, add: 1))
            XCTAssertEqual(f.guardrail.closeStatus, .residualOwned)
            XCTAssertFalse(f.guardrail.deletionAttempted)
        }
    }

    func testFakeReceiptFailureRefusesForwardingAndPreservesOwnershipFact() throws {
        for afterAdd in [false, true] {
            let f = try Fixture(record: { event in
                if !afterAdd || (event.phase == .add && event.status == .success) { throw Refusal.stop }
            })
            XCTAssertThrowsError(try f.guardrail.run(f.backend))
            XCTAssertEqual(f.fake.counts, afterAdd ? Counts(copy: 1, add: 1) : Counts())
            XCTAssertEqual(f.fake.dataReads, 0)
            XCTAssertEqual(f.fake.counts.delete, 0)
            XCTAssertEqual(f.guardrail.closeStatus, afterAdd ? .residualOwned : .refusedUnowned)
            XCTAssertTrue(f.guardrail.events.contains { $0.status == .receiptFailed })
        }
    }

    func testFakeInteractiveInputsAreRefusedExceptGuardedProductionDelete() throws {
        for operation in 0..<4 {
            let f = try Fixture()
            if operation > 0 { try require(f.backend.status(f.scope) == .missing) }
            if operation > 1 {
                try require(succeeded(f.backend.add(f.guardrail.first, scope: f.scope, interactive: false)))
            }
            if operation > 2 {
                try require(matches(f.backend.read(f.scope, interactive: false), f.guardrail.first))
            }
            let before = f.fake.counts
            switch operation {
            case 0:
                let backend = SecurityCredentialBackend(functions: rewrite(f.guardrail.functions) {
                    let context = LAContext(); context.interactionNotAllowed = false
                    $0[kSecUseAuthenticationContext as String] = context
                })
                _ = backend.status(f.scope)
            case 1: _ = f.backend.add(f.guardrail.first, scope: f.scope, interactive: true)
            case 2: _ = f.backend.read(f.scope, interactive: true)
            default: _ = f.backend.update(f.guardrail.second, scope: f.scope, interactive: true)
            }
            XCTAssertEqual(f.fake.counts, before)
        }
        let f = try Fixture()
        try f.guardrail.run(f.backend)
        XCTAssertTrue(f.guardrail.replacedInteractiveDelete && f.fake.freshContexts)
    }

    func testFakeReceiptAndErrorLabelsExcludeValuesAndReference() throws {
        let allowed: Set<String> = ["service", "account", "phase", "status", "counts", "matched"]
        for scenario in 0..<7 {
            let f = try Fixture()
            switch scenario {
            case 1: f.fake.preflight = errSecSuccess
            case 2: f.fake.addReference = nil
            case 3: f.fake.readStatus = errSecInteractionNotAllowed
            case 4: f.fake.mismatch = true
            case 5: f.fake.deleteStatus = errSecParam
            case 6: f.fake.postflight = errSecSuccess
            default: break
            }
            if scenario == 0 { try f.guardrail.run(f.backend) }
            else { XCTAssertThrowsError(try f.guardrail.run(f.backend)) }
            let encoded = try JSONEncoder().encode(f.guardrail.events)
            let text = String(decoding: encoded, as: UTF8.self)
            XCTAssertFalse(text.contains(f.guardrail.first) || text.contains(f.guardrail.second))
            XCTAssertFalse(text.contains(String(decoding: f.fake.reference, as: UTF8.self)))
            XCTAssertTrue(f.guardrail.events.allSatisfy {
                $0.service == Forwarder.service && $0.account == f.scope.account
            })
            let objects = try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]]
            XCTAssertTrue(objects?.allSatisfy { Set($0.keys).isSubset(of: allowed) } == true)
        }
        XCTAssertEqual(Refusal.stop.description, "Owned credential qualification refused.")
    }

    // Never activated by ordinary CI. Root must run the fake filter first, review,
    // then supervise this single synchronous invocation with its outer deadline.
    func testOwnedNativeSequence() throws {
        guard let toggle = getenv("PARLA_RUN_OWNED_KEYCHAIN_NATIVE"),
              String(cString: toggle) == "1" else {
            throw XCTSkip("Owned native credential qualification requires explicit opt-in.")
        }
        // Nothing above constructs Functions.system, a backend, or an LAContext.
        let scope = try CredentialScope.compatible("https://b07-\(UUID().uuidString.lowercased()).invalid/v1")
        let receipt = try PrivateReceipt()
        defer { receipt.close() }
        let guardrail = Forwarder(scope: scope, underlying: .system, record: receipt.append)
        let backend = SecurityCredentialBackend(functions: guardrail.functions)
        try guardrail.run(backend)
    }
}

private enum Refusal: Error, CustomStringConvertible {
    case stop
    var description: String { "Owned credential qualification refused." }
}

private func require(_ condition: Bool) throws {
    guard condition else { throw Refusal.stop }
}

private func succeeded(_ result: CredentialMutation) -> Bool {
    if case .success = result { return true }; return false
}

private func missing(_ result: CredentialRead) -> Bool {
    if case .missing = result { return true }; return false
}

private func matches(_ result: CredentialRead, _ expected: String) -> Bool {
    if case .value(let value) = result { return value == expected }; return false
}

private struct Counts: Codable, Equatable {
    var copy = 0
    var add = 0
    var update = 0
    var delete = 0
}

private enum Phase: String, Codable {
    case preflight, add, readFirst, update, readSecond, delete, staleRead, postflight
    case cleanupDelete, cleanupStaleRead, cleanupPostflight, closed
}

private enum Label: String, Codable {
    case ready, pending, success, missing, denied, canceled, duplicate, unsupported, unknown
    case refused, malformed, matched, mismatched, receiptFailed
    case complete, cleanupComplete, refusedUnowned, residualWithoutReference, residualOwned
    case removedUnconfirmed

    init(_ code: OSStatus) {
        switch code {
        case errSecSuccess: self = .success
        case errSecItemNotFound: self = .missing
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable: self = .denied
        case errSecUserCanceled: self = .canceled
        case errSecDuplicateItem: self = .duplicate
        case errSecParam: self = .unsupported
        default: self = .unknown
        }
    }
    var requiresStop: Bool {
        switch self {
        case .denied, .canceled, .unsupported, .unknown, .malformed, .refused, .receiptFailed: return true
        default: return false
        }
    }
}

private struct Event: Codable {
    let service: String
    let account: String
    let phase: Phase
    let status: Label
    let counts: Counts
    let matched: Bool?
}

// Real adapter queries are the inputs. This private gate is intentionally stricter
// than the default backend and changes forwarded deletion's interaction context.
private final class Forwarder {
    static let service = "com.parla.provider-credentials.v1"
    let scope: CredentialScope
    let first = UUID().uuidString
    let second = UUID().uuidString
    private let underlying: SecurityCredentialBackend.Functions
    private let record: (Event) throws -> Void
    private var reference: Data?
    private var phase = Phase.preflight
    private var stopped = false
    private var verifiedMissing = false
    private var cleaned = false
    private(set) var counts = Counts()
    private(set) var addSucceeded = false
    private(set) var deletionAttempted = false
    private(set) var removed = false
    private(set) var replacedInteractiveDelete = false
    private(set) var events: [Event] = []
    var owned: Bool { reference != nil }
    var closeStatus: Label {
        if verifiedMissing { return cleaned ? .cleanupComplete : .complete }
        if removed { return .removedUnconfirmed }
        if owned { return .residualOwned }
        return addSucceeded ? .residualWithoutReference : .refusedUnowned
    }

    init(scope: CredentialScope, underlying: SecurityCredentialBackend.Functions,
         record: @escaping (Event) throws -> Void = { _ in }) {
        self.scope = scope; self.underlying = underlying; self.record = record
    }

    var functions: SecurityCredentialBackend.Functions {
        .init(copy: { [self] in copy($0, $1) }, add: { [self] in add($0, $1) },
              update: { [self] in update($0, $1) }, delete: { [self] in delete($0) })
    }

    func run(_ backend: SecurityCredentialBackend) throws {
        do {
            try require(emit(.ready) && first != second)
            try require(backend.status(scope) == .missing && !stopped)
            try require(succeeded(backend.add(first, scope: scope, interactive: false)) && owned && !stopped)
            try check(backend.read(scope, interactive: false), expected: first)
            try require(succeeded(backend.update(second, scope: scope, interactive: false)) && !stopped)
            try check(backend.read(scope, interactive: false), expected: second)
            try require(succeeded(backend.delete(scope)) && !stopped)
            try require(missing(backend.read(scope, interactive: false)) && !stopped)
            try require(backend.status(scope) == .missing && !stopped)
            try require(verifiedMissing && counts == Counts(copy: 5, add: 1, update: 1, delete: 1))
            try require(emit(closeStatus))
        } catch {
            cleanupIfEligible(backend)
            phase = .closed
            _ = emit(closeStatus)
            throw Refusal.stop
        }
    }

    private func check(_ read: CredentialRead, expected: String) throws {
        let matched = matches(read, expected)
        try require(emit(matched ? .matched : .mismatched, matched: matched) && matched && !stopped)
    }

    func cleanupIfEligible(_ backend: SecurityCredentialBackend) {
        guard owned, !removed, !deletionAttempted, !stopped, !verifiedMissing else { return }
        cleaned = true; phase = .cleanupDelete
        guard succeeded(backend.delete(scope)), !stopped else { return }
        guard missing(backend.read(scope, interactive: false)), !stopped else { return }
        guard backend.status(scope) == .missing, !stopped else { return }
    }

    @discardableResult private func emit(_ status: Label, matched: Bool? = nil) -> Bool {
        let event = Event(service: Self.service, account: scope.account, phase: phase,
                          status: status, counts: counts, matched: matched)
        events.append(event)
        do { try record(event); return true }
        catch {
            stopped = true
            events.append(Event(service: Self.service, account: scope.account, phase: phase,
                                status: .receiptFailed, counts: counts, matched: nil))
            return false
        }
    }

    private func refuse() -> OSStatus {
        stopped = true; _ = emit(.refused); return errSecParam
    }

    private func outgoing(_ raw: CFDictionary, extra: [CFString], deletion: Bool = false,
                          bound: Bool = false) -> [String: Any]? {
        guard !stopped, phase != .closed, let q = raw as? [String: Any] else { return nil }
        let base = [kSecClass, kSecAttrService, kSecAttrAccount, kSecAttrSynchronizable,
                    kSecUseAuthenticationContext]
        guard Set(q.keys) == Set((base + extra).map { $0 as String }),
              q[kSecClass as String] as? String == kSecClassGenericPassword as String,
              q[kSecAttrService as String] as? String == Self.service,
              q[kSecAttrAccount as String] as? String == scope.account,
              q[kSecAttrSynchronizable as String] as? Bool == false,
              let original = q[kSecUseAuthenticationContext as String] as? LAContext,
              original.interactionNotAllowed == !deletion else { return nil }
        var forwarded = q
        if bound {
            guard addSucceeded, let reference, !reference.isEmpty else { return nil }
            forwarded[kSecValuePersistentRef as String] = reference
        }
        // No deprecated authentication-UI flag is introduced. All original identity
        // selectors stay in place; an unsupported combination is a finite refusal.
        let context = LAContext(); context.interactionNotAllowed = true
        forwarded[kSecUseAuthenticationContext as String] = context
        if deletion { replacedInteractiveDelete = !original.interactionNotAllowed }
        return forwarded
    }

    private func result(_ code: OSStatus) -> Label {
        let label = Label(code)
        if label.requiresStop { stopped = true }
        _ = emit(label)
        return label
    }

    private func copy(_ raw: CFDictionary, _ output: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        let attributes = phase == .preflight || phase == .postflight || phase == .cleanupPostflight
        let dataPhase = phase == .readFirst || phase == .readSecond || phase == .staleRead || phase == .cleanupStaleRead
        guard attributes || dataPhase,
              let q = outgoing(raw, extra: [attributes ? kSecReturnAttributes : kSecReturnData, kSecMatchLimit],
                               bound: !attributes),
              q[(attributes ? kSecReturnAttributes : kSecReturnData) as String] as? Bool == true,
              q[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String,
              attributes || output != nil else { return refuse() }
        counts.copy += 1
        guard emit(.pending) else { counts.copy -= 1; return errSecParam }
        var value: CFTypeRef?
        let code = underlying.copy(q as CFDictionary, &value)
        let label = result(code)
        if !attributes, label == .success {
            guard let data = value as? Data, !data.isEmpty,
                  let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                stopped = true; _ = emit(.malformed); return errSecDecode
            }
            output?.pointee = data as CFData
        }
        switch phase {
        case .preflight: phase = label == .missing ? .add : .closed
        case .readFirst: if label == .success { phase = .update }
        case .readSecond: if label == .success { phase = .delete }
        case .staleRead: if label == .missing { phase = .postflight }
        case .cleanupStaleRead: if label == .missing { phase = .cleanupPostflight }
        case .postflight, .cleanupPostflight:
            verifiedMissing = label == .missing && !stopped && removed
            phase = .closed
        default: break
        }
        return code
    }

    private func add(_ raw: CFDictionary, _ ignored: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        guard phase == .add, !addSucceeded, !owned, ignored == nil,
              var q = outgoing(raw, extra: [kSecValueData, kSecAttrAccessible]),
              q[kSecValueData as String] as? Data == Data(first.utf8),
              q[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        else { return refuse() }
        q[kSecReturnPersistentRef as String] = true
        counts.add += 1
        guard emit(.pending) else { counts.add -= 1; return errSecParam }
        var value: CFTypeRef?
        let code = underlying.add(q as CFDictionary, &value)
        // Ownership is based solely on actual successful add + its opaque result.
        // Update state before recording, so receipt I/O failure retains this fact.
        if code == errSecSuccess {
            addSucceeded = true
            if let data = value as? Data, !data.isEmpty { reference = data }
            else { stopped = true }
        }
        _ = result(code)
        phase = owned ? .readFirst : .closed
        return code
    }

    private func update(_ raw: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        guard phase == .update, !removed, !deletionAttempted,
              let q = outgoing(raw, extra: [], bound: true),
              let changes = attributes as? [String: Any],
              Set(changes.keys) == Set([kSecValueData as String]),
              changes[kSecValueData as String] as? Data == Data(second.utf8) else { return refuse() }
        counts.update += 1
        guard emit(.pending) else { counts.update -= 1; return errSecParam }
        let code = underlying.update(q as CFDictionary, attributes)
        if result(code) == .success { phase = .readSecond }
        return code
    }

    private func delete(_ raw: CFDictionary) -> OSStatus {
        guard phase == .delete || phase == .cleanupDelete,
              !removed, !deletionAttempted,
              let q = outgoing(raw, extra: [], deletion: true, bound: true) else { return refuse() }
        deletionAttempted = true; counts.delete += 1
        guard emit(.pending) else { counts.delete -= 1; return errSecParam }
        let code = underlying.delete(q as CFDictionary)
        if code == errSecSuccess { removed = true }
        let label = result(code)
        if label == .success { phase = cleaned ? .cleanupStaleRead : .staleRead }
        return code
    }
}

// No default underlying functions: every fake fixture supplies memory-only ports.
private final class Fixture {
    let scope: CredentialScope
    let fake: MemoryItems
    let guardrail: Forwarder
    let backend: SecurityCredentialBackend
    init(record: @escaping (Event) throws -> Void = { _ in }) throws {
        scope = try .compatible("https://b07-fake.invalid/v1")
        let fake = MemoryItems(); self.fake = fake
        let guardrail = Forwarder(scope: scope, underlying: fake.functions, record: record); self.guardrail = guardrail
        backend = SecurityCredentialBackend(functions: guardrail.functions)
    }
    func own() throws {
        try require(backend.status(scope) == .missing)
        try require(succeeded(backend.add(guardrail.first, scope: scope, interactive: false)) && guardrail.owned)
    }
}

private final class MemoryItems {
    let reference = Data("opaque-memory-reference".utf8)
    var addReference: CFTypeRef?
    var preflight: OSStatus = errSecItemNotFound
    var postflight: OSStatus?
    var addStatus: OSStatus = errSecSuccess
    var deleteStatus: OSStatus = errSecSuccess
    var readStatus: OSStatus?
    var mismatch = false
    var malformedRead = false
    private var value: Data?
    private var attributeChecks = 0
    private var contexts: [LAContext] = []
    private(set) var counts = Counts()
    private(set) var dataReads = 0
    private(set) var removals = 0
    private(set) var safeQueries = true
    private(set) var onlyOwnedReferences = true
    private(set) var freshContexts = true
    private(set) var staleReadUsedReference = false
    init() { addReference = reference as CFData }

    private func inspect(_ raw: CFDictionary, bound: Bool) -> [String: Any] {
        let q = raw as! [String: Any]
        let context = q[kSecUseAuthenticationContext as String] as? LAContext
        safeQueries = safeQueries && q[kSecClass as String] as? String == kSecClassGenericPassword as String
            && q[kSecAttrService as String] as? String == Forwarder.service
            && q[kSecAttrAccount as String] as? String == "openai-compatible|https://b07-fake.invalid/v1"
            && q[kSecAttrSynchronizable as String] as? Bool == false
            && context?.interactionNotAllowed == true
            && q[kSecUseAuthenticationUI as String] == nil
        if let context {
            freshContexts = freshContexts && !contexts.contains { $0 === context }
            contexts.append(context)
        } else { freshContexts = false }
        if bound { onlyOwnedReferences = onlyOwnedReferences && q[kSecValuePersistentRef as String] as? Data == reference }
        return q
    }

    var functions: SecurityCredentialBackend.Functions {
        .init(copy: { [self] raw, output in
            let attributes = (raw as! [String: Any])[kSecReturnAttributes as String] as? Bool == true
            let q = inspect(raw, bound: !attributes)
            counts.copy += 1
            if attributes {
                attributeChecks += 1
                if attributeChecks == 1 { return preflight }
                return postflight ?? (value == nil ? errSecItemNotFound : errSecSuccess)
            }
            dataReads += 1
            if let readStatus, readStatus != errSecSuccess { return readStatus }
            guard let value else {
                staleReadUsedReference = q[kSecValuePersistentRef as String] as? Data == reference
                return errSecItemNotFound
            }
            if !malformedRead { output?.pointee = (mismatch ? Data("different-private-value".utf8) : value) as CFData }
            return errSecSuccess
        }, add: { [self] raw, output in
            let q = inspect(raw, bound: false); counts.add += 1
            safeQueries = safeQueries && q[kSecReturnPersistentRef as String] as? Bool == true && output != nil
            if addStatus == errSecSuccess {
                value = q[kSecValueData as String] as? Data
                output?.pointee = addReference
            }
            return addStatus
        }, update: { [self] raw, attributes in
            _ = inspect(raw, bound: true); counts.update += 1
            guard value != nil else { return errSecItemNotFound }
            value = (attributes as! [String: Any])[kSecValueData as String] as? Data
            return errSecSuccess
        }, delete: { [self] raw in
            _ = inspect(raw, bound: true); counts.delete += 1
            if deleteStatus == errSecSuccess { value = nil; removals += 1 }
            return deleteStatus
        })
    }
}

// Tamper only with queries produced by the actual adapter; never synthesize a
// second production credential implementation for the fake checks.
private func rewrite(_ functions: SecurityCredentialBackend.Functions,
                     _ change: @escaping (inout [String: Any]) -> Void) -> SecurityCredentialBackend.Functions {
    func altered(_ raw: CFDictionary) -> CFDictionary {
        var q = raw as! [String: Any]; change(&q); return q as CFDictionary
    }
    return .init(copy: { functions.copy(altered($0), $1) }, add: { functions.add(altered($0), $1) },
                 update: { functions.update(altered($0), $1) }, delete: { functions.delete(altered($0)) })
}

// The parent recorder can consume this exclusive private JSONL receipt. No stdout
// identity logging, environment dictionary access, value/ref encoding or sweep.
private final class PrivateReceipt {
    private let handle: FileHandle
    init() throws {
        guard let raw = getenv("PARLA_OWNED_KEYCHAIN_RECEIPT") else { throw Refusal.stop }
        let path = String(cString: raw)
        guard path.hasPrefix("/"), !path.hasSuffix("/") else { throw Refusal.stop }
        let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw Refusal.stop }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    func append(_ event: Event) throws {
        do {
            var data = try JSONEncoder().encode(event); data.append(0x0A)
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch { throw Refusal.stop }
    }
    func close() { try? handle.close() }
}
