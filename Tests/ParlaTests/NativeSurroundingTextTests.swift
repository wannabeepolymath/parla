import XCTest
import ApplicationServices
@testable import Parla
@testable import ParlaCore

/// Synthetic AX field: the production reader/worker and timeout/reference logic
/// run unchanged. No real app, permission request, clipboard or provider is used.
final class SyntheticSurroundingAX: SurroundingAXAPI, @unchecked Sendable {
    enum Element: Equatable { case app, window, field, otherField }
    let lock = NSLock()
    var units = Array("Existing document context.".utf16)
    var caret: Int? = nil
    var role = "AXTextArea", subrole: String? = nil
    var bundle = "test.editor", field = Element.field
    var secure = false, editable = true
    var time: TimeInterval = 0
    var timeouts: [(Element, Float)] = [], requests: [NSRange] = []
    var onText: () -> Void = {}
    func focusedApplication() -> Element? { .app }
    func trusted() -> Bool { true }
    func secureInput() -> Bool { secure }
    func timeout(_ element: Element, seconds: Float) throws {
        XCTAssertGreaterThan(seconds, 0); XCTAssertLessThanOrEqual(seconds, 0.1)
        lock.withLock { timeouts.append((element, seconds)) }
    }
    func attribute(_ element: Element, _ name: String) throws -> SurroundingAXValue<Element>? {
        switch (element, name) {
        case (.app, kAXFocusedUIElementAttribute): return .element(field)
        case (.app, kAXFocusedWindowAttribute): return .element(.window)
        case (.field, kAXWindowAttribute), (.otherField, kAXWindowAttribute): return .element(.window)
        case (.field, kAXRoleAttribute), (.otherField, kAXRoleAttribute): return .string(role)
        case (.field, kAXSubroleAttribute), (.otherField, kAXSubroleAttribute): return subrole.map { .string($0) }
        case (.field, kAXSelectedTextRangeAttribute), (.otherField, kAXSelectedTextRangeAttribute): return .range(NSRange(location: caret ?? units.count, length: 0))
        case (.field, kAXNumberOfCharactersAttribute), (.otherField, kAXNumberOfCharactersAttribute): return .integer(units.count)
        default: XCTFail("Unexpected AX attribute: \(name)"); throw SurroundingTextFailure.refused
        }
    }
    func settable(_ element: Element) throws -> Bool { editable }
    func pid(_ element: Element) throws -> Int32 { 123 }
    func bundleID(_ pid: Int32) -> String? { bundle }
    func same(_ a: Element, _ b: Element) -> Bool { a == b }
    func text(_ element: Element, range: NSRange) throws -> [UInt16] {
        lock.withLock { requests.append(range) }
        let result = Array(units[range.location..<NSMaxRange(range)])
        onText()
        return result
    }
    var port: SurroundingTextPort { .usingAX(now: { self.lock.withLock { self.time } }) { self } }
}

final class NativeSurroundingTextTests: XCTestCase {
    private func open(_ api: SyntheticSurroundingAX, target: String = "test.editor") throws -> SurroundingTextOperation {
        try XCTUnwrap(api.port.open(UUID(), target))
    }
    @MainActor private func read(_ operation: SurroundingTextOperation) async throws -> SurroundingTextResponse {
        let observed = try await operation.proof(admit: { 1 })
        let field = try XCTUnwrap(observed)
        let read = try operation.issue(field, range: field.request, admit: { 1 })
        return try await read.value()
    }
    @MainActor func testNativeTimeoutRejectsLateReturnAndSetsEachReferenceTimeout() async throws {
        let good = SyntheticSurroundingAX(), success = try open(good)
        _ = try await read(success); await success.finishAndWaitForExit()
        XCTAssertTrue([SyntheticSurroundingAX.Element.app, .field, .window].allSatisfy { element in good.timeouts.contains { $0.0 == element } })
        let api = SyntheticSurroundingAX(), operation = try open(api)
        api.onText = { api.lock.withLock { api.time = 1 } }
        do { _ = try await read(operation); XCTFail("Deadline equality must refuse") } catch {}
        await operation.finishAndWaitForExit()
        XCTAssertEqual(api.requests.count, 1)
    }
    @MainActor func testNativeCaretOrFieldChangeDuringReadRefuses() async throws {
        let good = SyntheticSurroundingAX(), success = try open(good)
        _ = try await read(success); await success.finishAndWaitForExit()
        for moveField in [false, true] {
            let api = SyntheticSurroundingAX(), operation = try open(api)
            api.onText = { if moveField { api.field = .otherField } else { api.caret = 1 } }
            do { _ = try await read(operation); XCTFail("Changed destination accepted") } catch {}
            await operation.finishAndWaitForExit()
            XCTAssertEqual(api.requests.count, 1)
        }
    }
    @MainActor func testNativeSecurePasswordTerminalAndUnknownFieldsNeverReadText() async throws {
        let good = SyntheticSurroundingAX(), success = try open(good)
        _ = try await read(success); await success.finishAndWaitForExit()
        for kind in ["secure-input", "secure-field", "password-manager", "password-manager-dotted", "terminal", "integrated-terminal", "unknown"] {
            let api = SyntheticSurroundingAX()
            switch kind {
            case "secure-input": api.secure = true
            case "secure-field": api.subrole = "AXSecureTextField"
            case "password-manager": api.bundle = "com.agilebits.onepassword7"
            case "password-manager-dotted": api.bundle = "example.proton.pass"
            case "terminal": api.bundle = "com.apple.Terminal"
            case "integrated-terminal": api.bundle = "com.microsoft.VSCode"
            default: api.role = "AXUnknown"
            }
            let operation = try open(api, target: api.bundle)
            let field = try await operation.proof(admit: { 1 })
            XCTAssertNil(field, kind); XCTAssertTrue(api.requests.isEmpty, kind)
            await operation.finishAndWaitForExit()
        }
    }
    @MainActor func testNativeOversizeWindowTrimsAndChecksCaretUnicodeBoundary() async throws {
        let api = SyntheticSurroundingAX()
        api.units = Array((String(repeating: "old ", count: 1000) + " final words here").utf16)
        let operation = try open(api), response = try await read(operation)
        let prefix = try XCTUnwrap(try response.prefix(expected: response.field))
        let prompt = PromptBuilder.user(transcript: "new speech", context: {
            var context = CleanupContext(dictionary: [], snippets: [:], appName: nil); context.precedingText = prefix; return context
        }())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(prompt.utf8)) as? [String: String])
        let text = try XCTUnwrap(json["preceding_text"])
        XCTAssertLessThanOrEqual(text.utf16.count, 256); XCTAssertLessThanOrEqual(text.utf8.count, 1024)
        XCTAssertTrue(text.hasSuffix("final words here")); XCTAssertEqual(api.requests, [NSRange(location: api.units.count - 512, length: 512)])
        await operation.finishAndWaitForExit()
        let middle = SyntheticSurroundingAX(); middle.units = Array("hello world".utf16); middle.caret = 5
        let middleOperation = try open(middle), middleResponse = try await read(middleOperation)
        XCTAssertNotNil(try middleResponse.prefix(expected: middleResponse.field))
        XCTAssertEqual(middle.requests, [NSRange(location: 0, length: 5), NSRange(location: 5, length: 2)])
        await middleOperation.finishAndWaitForExit()
        let split = SyntheticSurroundingAX(); split.units = Array("a\u{0301} tail".utf16); split.caret = 1
        let splitOperation = try open(split)
        do { _ = try await read(splitOperation); XCTFail("Split grapheme accepted") } catch {}
        await splitOperation.finishAndWaitForExit()
    }
    @MainActor func testNativeCancellationDrainsHeldReadBeforeScopeExit() async throws {
        let api = SyntheticSurroundingAX(), operation = try open(api)
        let entered = expectation(description: "Native range read entered"), exited = expectation(description: "Owned worker exited")
        let earlyExit = expectation(description: "No caller exit before worker release"); earlyExit.isInverted = true
        let gate = DispatchSemaphore(value: 0)
        api.onText = { entered.fulfill(); gate.wait() }
        let observed = try await operation.proof(admit: { 1 })
        let field = try XCTUnwrap(observed)
        let handle = try operation.issue(field, range: field.request, admit: { 1 })
        let state = B26NativeDrainState()
        let task = Task {
            do { _ = try await handle.value(); XCTFail("Canceled read accepted") } catch {}
            await operation.finishAndWaitForExit()
            if !state.released { earlyExit.fulfill() }
            state.finished = true; exited.fulfill()
        }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel(); operation.cancel()
        await fulfillment(of: [earlyExit], timeout: 0.05)
        XCTAssertFalse(state.finished)
        state.released = true; gate.signal()
        await fulfillment(of: [exited], timeout: 2); await task.value
        XCTAssertTrue(state.finished)
        do { _ = try await operation.proof(admit: { 1 }); XCTFail("Closed scope reopened") } catch {}
    }
    @MainActor func testNativeContextNeverReachesHistoryDiagnosticsOrOrdinaryRequest() async throws {
        let d = try B26AppDocument(), r = try B26AppRig(d), session = try r.start()
        let api = SyntheticSurroundingAX(), http = B26AppHTTP()
        let sentinel = "PRIVATE_EXISTING_DOCUMENT_SENTINEL"
        api.units = Array(sentinel.utf16); http.text = "Cleaned dictated speech."
        await r.work(session, field: B26AppField(), http: http, port: api.port).value
        XCTAssertEqual(http.resumed, 1); XCTAssertEqual(r.categories, 0)
        XCTAssertTrue(String(decoding: try XCTUnwrap(http.requests.first?.httpBody), as: UTF8.self).contains(sentinel))
        XCTAssertEqual(r.posted, ["Cleaned dictated speech."])
        XCTAssertFalse(String(decoding: d.historyBytes, as: UTF8.self).contains(sentinel))
        XCTAssertNil(d.history.entries.first?.cleaned); XCTAssertEqual(d.history.entries.first?.raw, r.raw)
        let receipt = r.diagnostics.snapshot()
        XCTAssertFalse(receipt.records.isEmpty)
        let diagnostic = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        XCTAssertFalse(diagnostic.contains(sentinel)); XCTAssertFalse(r.logs.joined().contains(sentinel))
        XCTAssertTrue(r.learned.isEmpty)
        let ordinary = try B26AppDocument(), baseline = try B26AppRig(ordinary), unreviewed = try baseline.start(reviewed: false)
        let unread = SyntheticSurroundingAX(), unusedHTTP = B26AppHTTP()
        unread.units = Array(sentinel.utf16)
        await baseline.work(unreviewed, field: B26AppField(), http: unusedHTTP, port: unread.port).value
        XCTAssertTrue(unread.requests.isEmpty); XCTAssertEqual(unusedHTTP.constructed, 0); XCTAssertEqual(baseline.categories, 1)
        XCTAssertFalse(String(decoding: try XCTUnwrap(baseline.categoryBodies.first), as: UTF8.self).contains(sentinel))
    }
    @MainActor func testLocalDefaultUsesNativeContextWithoutCloudOrCredentialAccess() async throws {
        let d = try B26AppDocument(provider: "apple-intelligence")
        try d.patch { root in
            var cleanup = root["cleanup"] as! [String: Any]; cleanup["localSourceLocale"] = "en"; root["cleanup"] = cleanup
            root["profiles"] = [] // The default must work without creating an app profile.
        }
        let r = try B26AppRig(d), session = try r.start(reviewed: false)
        XCTAssertNotNil(session.surroundingTextGrant)
        let api = SyntheticSurroundingAX(), http = B26AppHTTP()
        api.units = Array("PRIVATE_LOCAL_DOCUMENT_CONTEXT".utf16)
        r.raw = "Please review the complete proposal before the meeting tomorrow"
        let state = B26LocalPromptState()
        let runtime = LocalCleanupRuntime(availability: { _ in nil }, language: { _ in ["en": 0.99] }, generate: { prompt, attempted in
            try attempted(); state.prompts.append(prompt)
            return "Please review the complete proposal before the meeting tomorrow."
        }, now: { 100 }, sleep: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }, appLocale: { "en" })
        await r.work(session, field: B26AppField(), http: http, port: api.port, localRuntime: runtime).value
        XCTAssertEqual(state.prompts.count, 1)
        XCTAssertTrue(state.prompts.first?.user.contains("PRIVATE_LOCAL_DOCUMENT_CONTEXT") == true)
        XCTAssertEqual(http.constructed, 0); XCTAssertEqual(r.categories, 0); XCTAssertEqual(d.backend.reads, 0)
        XCTAssertEqual(r.posted, ["Please review the complete proposal before the meeting tomorrow."])
        XCTAssertNil(d.history.entries.first?.cleaned)
        XCTAssertFalse(String(decoding: d.historyBytes, as: UTF8.self).contains("PRIVATE_LOCAL_DOCUMENT_CONTEXT"))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(r.diagnostics.snapshot()), as: UTF8.self).contains("PRIVATE_LOCAL_DOCUMENT_CONTEXT"))
    }

}
@MainActor private final class B26NativeDrainState { var finished = false, released = false }

private final class B26LocalPromptState: @unchecked Sendable { var prompts: [LocalCleanupPrompt] = [] }
