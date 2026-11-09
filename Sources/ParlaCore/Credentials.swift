import Foundation
import Security
import LocalAuthentication

/// Identity and request construction share this canonical base. No secret-bearing URL parts.
public struct CredentialScope: Hashable, Sendable {
    public let account: String
    public let baseURL: String
    public static let anthropic = CredentialScope(account: "anthropic", baseURL: "https://api.anthropic.com")

    public static func compatible(_ raw: String?) throws -> CredentialScope {
        guard let raw, var c = URLComponents(string: raw),
              let scheme = c.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = c.host?.lowercased(), !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.port.map({ (1...65535).contains($0) }) ?? true else {
            throw CredentialFailure("Enter a valid http or https base URL.")
        }
        c.scheme = scheme; c.host = host
        if c.port == (scheme == "https" ? 443 : 80) { c.port = nil }
        while c.percentEncodedPath.hasSuffix("/") { c.percentEncodedPath.removeLast() }
        guard let base = c.url?.absoluteString else { throw CredentialFailure("Invalid cleanup.baseURL.") }
        return CredentialScope(account: "openai-compatible|" + base, baseURL: base)
    }

    public static func selected(_ settings: Settings) throws -> CredentialScope {
        switch settings.cleanup.provider {
        case "", "anthropic": return .anthropic
        case "openai-compatible": return try compatible(settings.cleanup.baseURL)
        default: throw CredentialFailure("Unknown cleanup provider in settings.json. Use \"anthropic\" or \"openai-compatible\".")
        }
    }
}

public struct CredentialFailure: Error, LocalizedError, CustomStringConvertible {
    public let description: String
    public var errorDescription: String? { description }
    public let status: CredentialStatus?
    public init(_ description: String, status: CredentialStatus? = nil) { self.description = description; self.status = status }
}

public enum CredentialStatus: String, Equatable, Sendable {
    case present, missing, denied, canceled, error
    public var message: String {
        switch self {
        case .present: return "Key stored in Keychain."
        case .missing: return "No key saved. Local servers may not need one."
        case .denied: return "Keychain access was denied. In Keychain Access, delete \"com.parla.provider-credentials.v1\", then add your key again."
        case .canceled: return "Keychain access was canceled. Try again."
        case .error: return "Couldn’t read the key. Try again or replace it."
        }
    }
}

/// Never Codable or printed. Only deliberate request preparation consumes a value.
public enum CredentialRead {
    case value(String), missing, denied, canceled, error
    var status: CredentialStatus {
        switch self {
        case .value: return .present
        case .missing: return .missing
        case .denied: return .denied
        case .canceled: return .canceled
        case .error: return .error
        }
    }
}
public enum CredentialMutation { case success, duplicate, missing, denied, canceled, error }

public protocol CredentialBackend {
    func status(_ scope: CredentialScope) -> CredentialStatus
    func read(_ scope: CredentialScope, interactive: Bool) -> CredentialRead
    func add(_ value: String, scope: CredentialScope, interactive: Bool) -> CredentialMutation
    func update(_ value: String, scope: CredentialScope, interactive: Bool) -> CredentialMutation
    func delete(_ scope: CredentialScope) -> CredentialMutation
}

public final class CredentialStore {
    public static let shared = CredentialStore(backend: SecurityCredentialBackend())
    private let backend: CredentialBackend
    public init(backend: CredentialBackend) { self.backend = backend }
    public func status(_ scope: CredentialScope) -> CredentialStatus { backend.status(scope) }
    public func read(_ scope: CredentialScope, interactive: Bool) -> CredentialRead { backend.read(scope, interactive: interactive) }

    /// Migration is add-only. Duplicate races must be read back, never overwritten.
    public func migrate(_ value: String, scope: CredentialScope) throws {
        switch backend.read(scope, interactive: false) {
        case .value(let existing):
            guard existing == value else { throw CredentialFailure("A different key is already in Keychain. Save your key again to replace it.") }
        case .missing:
            let result = backend.add(value, scope: scope, interactive: false)
            switch result {
            case .success, .duplicate: break
            default: throw failure(result)
            }
        case let result: throw CredentialFailure(result.status.message + " Your API key hasn’t moved to Keychain yet.")
        }
        switch backend.read(scope, interactive: false) {
        case .value(let verified):
            guard verified == value else { throw CredentialFailure("A different key is already in Keychain. Save your key again to replace it.") }
        default: throw CredentialFailure("Couldn’t move your API key to Keychain. Click Refresh to try again.")
        }
    }
    public func replace(_ value: String, scope: CredentialScope) throws {
        guard !value.isEmpty else { return }
        let result: CredentialMutation
        switch backend.status(scope) {
        case .missing:
            let added = backend.add(value, scope: scope, interactive: true)
            if case .duplicate = added { result = backend.update(value, scope: scope, interactive: true) }
            else { result = added }
        default: result = backend.update(value, scope: scope, interactive: true)
        }
        guard case .success = result else { throw failure(result) }
        guard case .value(let verified) = backend.read(scope, interactive: true), verified == value else {
            throw CredentialFailure("Couldn’t save the key. Try again.")
        }
    }
    public func remove(_ scope: CredentialScope) throws {
        switch backend.delete(scope) {
        case .success, .missing: return
        case let result: throw failure(result)
        }
    }
    private func failure(_ result: CredentialMutation) -> CredentialFailure {
        switch result {
        case .denied: return CredentialFailure(CredentialStatus.denied.message)
        case .canceled: return CredentialFailure(CredentialStatus.canceled.message)
        default: return CredentialFailure("Couldn’t update the key. Try again.")
        }
    }
}

/// Generic passwords, app-owned stable service, local device only. No custom ACL,
/// trusted binary list, synchronizing item or shared access group is introduced.
public final class SecurityCredentialBackend: CredentialBackend {
    public struct Functions {
        public var copy: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
        public var add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
        public var update: (CFDictionary, CFDictionary) -> OSStatus
        public var delete: (CFDictionary) -> OSStatus
        public init(copy: @escaping (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus,
                    add: @escaping (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus,
                    update: @escaping (CFDictionary, CFDictionary) -> OSStatus,
                    delete: @escaping (CFDictionary) -> OSStatus) {
            self.copy = copy; self.add = add; self.update = update; self.delete = delete
        }
        public static let system = Functions(copy: SecItemCopyMatching, add: SecItemAdd,
                                             update: SecItemUpdate, delete: SecItemDelete)
    }
    private let functions: Functions
    public init(functions: Functions = .system) { self.functions = functions }
    /// LAContext/kSecUseAuthenticationUIFail do not stop the login-keychain
    /// "wants to access key" dialog (an item saved by a differently signed build).
    /// This process-wide switch does: such reads fail as .denied instead of prompting.
    static let keychainUIDisabled: Void = { _ = SecKeychainSetUserInteractionAllowed(false) }()
    private func query(_ scope: CredentialScope, interactive: Bool) -> [String: Any] {
        Self.keychainUIDisabled
        let context = LAContext(); context.interactionNotAllowed = !interactive
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.parla.provider-credentials.v1",
                kSecAttrAccount as String: scope.account,
                kSecAttrSynchronizable as String: false,
                kSecUseAuthenticationContext as String: context]
    }
    public func status(_ scope: CredentialScope) -> CredentialStatus {
        // Attributes only: status never retrieves the password or allows UI.
        var q = query(scope, interactive: false)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return state(functions.copy(q as CFDictionary, &result))
    }
    public func read(_ scope: CredentialScope, interactive: Bool) -> CredentialRead {
        var q = query(scope, interactive: interactive)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = state(functions.copy(q as CFDictionary, &result))
        switch status {
        case .present:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else { return .error }
            return .value(value)
        case .missing: return .missing
        case .denied: return .denied
        case .canceled: return .canceled
        case .error: return .error
        }
    }
    public func add(_ value: String, scope: CredentialScope, interactive: Bool) -> CredentialMutation {
        var q = query(scope, interactive: interactive)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return mutation(functions.add(q as CFDictionary, nil))
    }
    public func update(_ value: String, scope: CredentialScope, interactive: Bool) -> CredentialMutation {
        mutation(functions.update(query(scope, interactive: interactive) as CFDictionary,
                                  [kSecValueData as String: Data(value.utf8)] as CFDictionary))
    }
    public func delete(_ scope: CredentialScope) -> CredentialMutation {
        mutation(functions.delete(query(scope, interactive: true) as CFDictionary))
    }
    private func state(_ code: OSStatus) -> CredentialStatus {
        switch code {
        case errSecSuccess: return .present
        case errSecItemNotFound: return .missing
        case errSecUserCanceled: return .canceled
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecNotAvailable: return .denied
        default: return .error
        }
    }
    private func mutation(_ code: OSStatus) -> CredentialMutation {
        if code == errSecDuplicateItem { return .duplicate }
        switch state(code) {
        case .present: return .success
        case .missing: return .missing
        case .denied: return .denied
        case .canceled: return .canceled
        case .error: return .error
        }
    }
}
