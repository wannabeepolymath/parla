import AppKit
import ApplicationServices
import Carbon
import ParlaCore

/// This is the entire native surface. No full value, selected text, clipboard,
/// hierarchy search, AX wake-up, or permission prompt is available to the reader.
enum SurroundingAXValue<Element> {
    case element(Element), string(String), integer(Int), range(NSRange)
}
protocol SurroundingAXAPI {
    associatedtype Element
    func focusedApplication() -> Element?
    func trusted() -> Bool
    func secureInput() -> Bool
    func timeout(_ element: Element, seconds: Float) throws
    func attribute(_ element: Element, _ name: String) throws -> SurroundingAXValue<Element>?
    func settable(_ element: Element) throws -> Bool
    func pid(_ element: Element) throws -> Int32
    func bundleID(_ pid: Int32) -> String?
    func same(_ a: Element, _ b: Element) -> Bool
    func text(_ element: Element, range: NSRange) throws -> [UInt16]
}

struct NativeSurroundingAX: SurroundingAXAPI {
    func focusedApplication() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication, !app.isTerminated else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier)
    }
    func trusted() -> Bool { AXIsProcessTrusted() }
    func secureInput() -> Bool { IsSecureEventInputEnabled() }
    func timeout(_ element: AXUIElement, seconds: Float) throws {
        guard AXUIElementSetMessagingTimeout(element, seconds) == .success else { throw SurroundingTextFailure.refused }
    }
    func attribute(_ element: AXUIElement, _ name: String) throws -> SurroundingAXValue<AXUIElement>? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if status == .attributeUnsupported || status == .noValue { return nil }
        guard status == .success, let value else { throw SurroundingTextFailure.refused }
        if CFGetTypeID(value) == AXUIElementGetTypeID() { return .element(unsafeBitCast(value, to: AXUIElement.self)) }
        if CFGetTypeID(value) == CFStringGetTypeID(), let string = value as? String { return .string(string) }
        if CFGetTypeID(value) == CFNumberGetTypeID(), let number = value as? NSNumber { return .integer(number.intValue) }
        if CFGetTypeID(value) == AXValueGetTypeID() {
            let ax = unsafeBitCast(value, to: AXValue.self)
            var range = CFRange()
            if AXValueGetType(ax) == .cfRange, AXValueGetValue(ax, .cfRange, &range), range.location >= 0, range.length >= 0 {
                return .range(NSRange(location: range.location, length: range.length))
            }
        }
        throw SurroundingTextFailure.refused
    }
    func settable(_ element: AXUIElement) throws -> Bool {
        var value = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &value) == .success else { throw SurroundingTextFailure.refused }
        return value.boolValue
    }
    func pid(_ element: AXUIElement) throws -> Int32 {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { throw SurroundingTextFailure.refused }
        return pid
    }
    func bundleID(_ pid: Int32) -> String? { NSRunningApplication(processIdentifier: pid)?.bundleIdentifier }
    func same(_ a: AXUIElement, _ b: AXUIElement) -> Bool { CFEqual(a, b) }
    func text(_ element: AXUIElement, range: NSRange) throws -> [UInt16] {
        guard range.location >= 0, range.length <= 512 else { throw SurroundingTextFailure.refused }
        var requested = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &requested) else { throw SurroundingTextFailure.refused }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
              let value, CFGetTypeID(value) == CFStringGetTypeID() else { throw SurroundingTextFailure.refused }
        let string = unsafeBitCast(value, to: CFString.self)
        // Check the foreign result before making a Swift copy. Never truncate an
        // over-returning application into apparent compliance with the request.
        guard CFStringGetLength(string) == range.length else { throw SurroundingTextFailure.refused }
        var units = [UInt16](repeating: 0, count: range.length)
        if !units.isEmpty { CFStringGetCharacters(string, CFRange(location: 0, length: range.length), &units) }
        return units
    }
}

/// One operation, one serial worker. Every native entry has a positive timeout
/// on THAT reference (AX timeouts are not inherited), bounded by the absolute
/// job deadline. A late native return is rejected and still joined, never detached.
private final class SurroundingAXReader<API: SurroundingAXAPI> {
    let api: API
    let target: String
    var sealed: (app: API.Element, window: API.Element, field: API.Element, proof: SurroundingTextField, count: Int)?
    init(api: API, target: String) { self.api = api; self.target = target }

    static func allowedApp(_ bundle: String) -> Bool {
        let lower = bundle.lowercased().filter { $0.isLetter || $0.isNumber }
        let forbidden = ["1password", "onepassword", "agilebits", "bitwarden", "lastpass", "dashlane", "keepass", "enpass", "strongbox", "keychain", "password", "protonpass", "nordpass", "msecure", "keeweb", "buttercup", "lockwise", "passbolt", "padloc", "roboform", "safeincloud", "keeper", "secrets", "terminal", "iterm", "ghostty", "wezterm", "alacritty", "kitty", "hyper", "warp", "remote", "teamviewer", "anydesk"]
        return !bundle.isEmpty && !forbidden.contains(where: lower.contains)
            && !TextRules.isBrowser(bundleID: bundle)
            && ![AppCategory.terminal, .code].contains(TextRules.category(bundleID: bundle))
    }

    func proof(check: () throws -> Void, remaining: () throws -> Float) throws -> SurroundingTextField? {
        try check()
        guard api.trusted(), !api.secureInput(), Self.allowedApp(target) else { return nil }
        func get(_ element: API.Element, _ name: String) throws -> SurroundingAXValue<API.Element>? {
            try check(); try api.timeout(element, seconds: remaining()); try check()
            let value = try api.attribute(element, name); try check(); return value
        }
        // Never set a timeout on AXUIElementCreateSystemWide(): that would
        // change the process-wide timeout for unrelated Accessibility features.
        guard let app = api.focusedApplication(),
              case .element(let field) = try get(app, kAXFocusedUIElementAttribute) else { return nil }
        try check(); let pid = try api.pid(app); try check()
        guard pid > 0, api.bundleID(pid) == target else { return nil }
        try check(); guard try api.pid(field) == pid else { return nil }
        guard case .string(let role) = try get(field, kAXRoleAttribute),
              ["AXTextField", "AXTextArea", "AXSearchField"].contains(role) else { return nil }
        // Unknown subrole failures throw. Absent subrole is standard AX behavior.
        if let subrole = try get(field, kAXSubroleAttribute) {
            guard case .string(let name) = subrole, !name.lowercased().contains("secure"), !name.lowercased().contains("password") else { return nil }
        }
        try check(); try api.timeout(field, seconds: remaining()); try check()
        guard try api.settable(field) else { return nil }
        guard case .element(let window) = try get(field, kAXWindowAttribute),
              case .element(let focusedWindow) = try get(app, kAXFocusedWindowAttribute), api.same(window, focusedWindow),
              case .range(let selection) = try get(field, kAXSelectedTextRangeAttribute), selection.length == 0,
              case .integer(let count) = try get(field, kAXNumberOfCharactersAttribute), count >= 0,
              selection.location >= 0, selection.location <= count else { return nil }
        try check(); try api.timeout(window, seconds: remaining()); try check()
        guard try api.pid(window) == pid, !api.secureInput(),
              let front = api.focusedApplication(), api.same(app, front) else { return nil }
        // AX supplies a collapsed native caret. The range read additionally
        // verifies its Unicode boundary before any prefix can leave the worker.
        let proof = SurroundingTextField(pid: pid, window: 1, field: 1, app: target, caret: selection.location,
            selectionLength: selection.length, safe: true, qualified: true, caretBoundaryProved: true)
        if let old = sealed {
            guard api.same(app, old.app), api.same(window, old.window), api.same(field, old.field),
                  old.proof == proof, old.count == count else { throw SurroundingTextFailure.refused }
        } else { sealed = (app, window, field, proof, count) }
        try check(); return proof
    }

    func read(_ expected: SurroundingTextField, range: NSRange, check: () throws -> Void,
              remaining: () throws -> Float) throws -> SurroundingTextResponse {
        guard try proof(check: check, remaining: remaining) == expected, let sealed,
              range == expected.request else { throw SurroundingTextFailure.refused }
        func text(_ range: NSRange) throws -> [UInt16] {
            try check(); try api.timeout(sealed.field, seconds: remaining()); try check()
            let result = try api.text(sealed.field, range: range); try check()
            guard result.count == range.length else { throw SurroundingTextFailure.refused }
            return result
        }
        let units = range.length == 0 ? [] : try text(range)
        // A truncated leading grapheme is discarded through a provable break.
        // LF always breaks; an ASCII letter/digit after a space/tab also breaks.
        // Refuse rather than guess for an unbroken/complex truncated window.
        let discard: Int
        if range.location == 0 { discard = 0 }
        else if let boundary = units.indices.dropFirst().first(where: { index in
            units[index - 1] == 10 || ([9, 32].contains(units[index - 1]) && ((48...57).contains(units[index]) || (65...90).contains(units[index]) || (97...122).contains(units[index])))
        }) { discard = boundary }
        else { throw SurroundingTextFailure.refused }
        let preceding = Array(units.dropFirst(discard))
        // At most two following units are inspected locally to verify the caret
        // is a grapheme boundary; they are never retained in provider context.
        let after = min(2, sealed.count - expected.caret)
        let following = after == 0 ? [] : try text(NSRange(location: expected.caret, length: after))
        let scalarLength = following.first.map { (0xD800...0xDBFF).contains($0) ? 2 : 1 } ?? 0
        let probe = preceding + following.prefix(scalarLength)
        let string = String(decoding: probe, as: UTF16.self)
        guard Array(string.utf16) == probe,
              let caret = String.Index(utf16Offset: preceding.count, in: string).samePosition(in: string),
              caret == string.endIndex || string.indices.contains(caret) else { throw SurroundingTextFailure.refused }
        guard try proof(check: check, remaining: remaining) == expected else { throw SurroundingTextFailure.refused }
        return SurroundingTextResponse(field: expected, range: range, units: units, startBoundaryProved: true, discardLeadingUnits: discard)
    }
    func close() { sealed = nil }
}

private final class SurroundingAXWorker<API: SurroundingAXAPI>: @unchecked Sendable {
    let queue = DispatchQueue(label: "app.parla.surrounding-text", qos: .userInitiated)
    let reader: SurroundingAXReader<API>
    let now: () -> TimeInterval
    private let lock = NSLock()
    private var canceled = false
    init(api: API, target: String, now: @escaping () -> TimeInterval) { reader = .init(api: api, target: target); self.now = now }
    func cancel() { lock.withLock { canceled = true } }
    func job<T>(admit: @escaping SurroundingTextOperation.Admit, work: @escaping (SurroundingAXReader<API>, () throws -> Void, () throws -> Float) throws -> T) async throws -> T {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        let deadline = self.now() + min(1, try admit())
                        func remaining() throws -> Float {
                            guard !self.lock.withLock({ self.canceled }) else { throw SurroundingTextFailure.refused }
                            let left = min(try admit(), deadline - self.now())
                            guard left.isFinite, left > 0 else { throw SurroundingTextFailure.refused }
                            return Float(min(0.1, left))
                        }
                        func check() throws { _ = try remaining() }
                        try check()
                        let value = try work(self.reader, check, remaining)
                        try check(); continuation.resume(returning: value)
                    } catch { continuation.resume(throwing: SurroundingTextFailure.refused) }
                }
            }
        }, onCancel: { self.cancel() })
    }
    func finish() async {
        await withCheckedContinuation { continuation in queue.async { self.reader.close(); continuation.resume() } }
    }
}

extension SurroundingTextPort {
    static let native = usingAX { NativeSurroundingAX() }
    static func usingAX<API: SurroundingAXAPI>(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                                             _ factory: @escaping () -> API) -> Self {
        .init { id, target in
            let worker = SurroundingAXWorker(api: factory(), target: target, now: now)
            return SurroundingTextOperation(operationID: id, target: target, proof: { admit in
                try await worker.job(admit: admit) { reader, check, remaining in try reader.proof(check: check, remaining: remaining) }
            }, issue: { field, range, _, admit in
                SurroundingTextRead(value: {
                    try await worker.job(admit: admit) { reader, check, remaining in try reader.read(field, range: range, check: check, remaining: remaining) }
                }, cancel: { worker.cancel() })
            }, finishAndWaitForExit: { await worker.finish() })
        }
    }
}
