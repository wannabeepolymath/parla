import Foundation
import CryptoKit
import Security

public enum ParakeetRefusal: String, Error, Sendable {
    case needsPreparation, needsTrustedProduct, configuration, unsupportedHost, codeIdentity, resourceIdentity
}
public struct ParakeetProductIdentity: Equatable, Codable, Sendable {
    public let protocolVersion: Int
    public let adapterRevision: Int
    public let sdk: String
    public let helperSHA256: String
    public let sourceSHA256: String
    public let resources: [String: String]
    public let team: String
}
public struct ParakeetTrustedProduct: Sendable {
    public let identity: ParakeetProductIdentity
    public let executable: URL
    init(identity: ParakeetProductIdentity, executable: URL) { self.identity = identity; self.executable = executable }
}
public struct ParakeetTrustBottom {
    public var host: () throws -> Void
    public var read: (URL, Int) throws -> Data
    public var signature: (URL, String) throws -> Void
    public init(host: @escaping () throws -> Void, read: @escaping (URL, Int) throws -> Data,
                signature: @escaping (URL, String) throws -> Void) {
        self.host = host; self.read = read; self.signature = signature
    }
    public static var system: Self {
        Self(host: {
            #if arch(arm64)
            guard #available(macOS 14, *) else { throw ParakeetRefusal.unsupportedHost }
            #else
            throw ParakeetRefusal.unsupportedHost
            #endif
        }, read: { url, maximum in
            let parts = url.standardizedFileURL.pathComponents
            var ancestor = URL(fileURLWithPath: "/", isDirectory: true)
            for part in parts.dropFirst() {
                ancestor.appendPathComponent(part)
                let values = try ancestor.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw ParakeetRefusal.codeIdentity }
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= maximum else { throw ParakeetRefusal.codeIdentity }
            let data = try Data(contentsOf: url)
            guard data.count == size else { throw ParakeetRefusal.codeIdentity }
            return data
        }, signature: { url, team in
            guard !team.isEmpty, team.utf8.count <= 32, team.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) else { throw ParakeetRefusal.codeIdentity }
            var code: SecStaticCode?
            var requirement: SecRequirement?
            let policy = "anchor apple generic and identifier \"com.parla.ParlaParakeetHelper\" and certificate leaf[subject.OU] = \"\(team)\""
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
                  SecRequirementCreateWithString(policy as CFString, [], &requirement) == errSecSuccess,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else { throw ParakeetRefusal.codeIdentity }
        })
    }
}

public enum ParakeetTrust {
    public static let relativeBundle = "Contents/Helpers/ParlaParakeetHelper.bundle"
    public static let relativeExecutable = "Contents/MacOS/ParlaParakeetHelper"
    /// G3 must supply an independently expected fresh product identity; a receipt
    /// read from the optional bundle is never its own trust authority.
    public static func admit(expected: ParakeetProductIdentity, app: URL = Bundle.main.bundleURL,
                             bottom: ParakeetTrustBottom = .system) throws -> ParakeetTrustedProduct {
        try bottom.host()
        let bundle = app.appendingPathComponent(relativeBundle, isDirectory: true)
        let executable = bundle.appendingPathComponent(relativeExecutable)
        guard expected.protocolVersion == 1, expected.adapterRevision == 1, expected.sdk == ParakeetWire.sdk,
              isSHA256(expected.helperSHA256), isSHA256(expected.sourceSHA256), !expected.resources.isEmpty,
              expected.resources.count <= 512,
              expected.resources.allSatisfy({ isResource($0.key) && isSHA256($0.value) }) else { throw ParakeetRefusal.codeIdentity }
        let descriptor = try bottom.read(app.appendingPathComponent("Contents/Resources/parakeet-product.json"), 131_072)
        let observed = try JSONDecoder().decode(ParakeetProductIdentity.self, from: descriptor)
        guard observed == expected else { throw ParakeetRefusal.codeIdentity }
        let binary = try bottom.read(executable, 128 * 1024 * 1024)
        guard SHA256.hash(data: binary).hex == expected.helperSHA256, try arm64MacOS14(binary) else { throw ParakeetRefusal.codeIdentity }
        for (path, hash) in expected.resources {
            let data = try bottom.read(bundle.appendingPathComponent(path), 16 * 1024 * 1024)
            guard SHA256.hash(data: data).hex == hash else { throw ParakeetRefusal.resourceIdentity }
        }
        try bottom.signature(bundle, expected.team)
        return ParakeetTrustedProduct(identity: expected, executable: executable)
    }
    private static func isSHA256(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func isResource(_ path: String) -> Bool {
        path.hasPrefix("Contents/Resources/") && path.utf8.count <= 1024 &&
        path.split(separator: "/").allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." } && !path.contains("\0")
    }
    private static func arm64MacOS14(_ data: Data) throws -> Bool {
        func u32(_ i: Int) throws -> UInt32 {
            guard i >= 0, i <= data.count - 4 else { throw ParakeetRefusal.codeIdentity }
            return UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
        }
        guard data.count >= 32, try u32(0) == 0xfeedfacf, try u32(4) == 0x0100000c, try u32(12) == 2 else { return false }
        let count = Int(try u32(16)), bytes = Int(try u32(20))
        guard count <= 4096, bytes <= data.count - 32 else { return false }
        var cursor = 32; var found = false
        for _ in 0..<count {
            let kind = try u32(cursor), size = Int(try u32(cursor + 4))
            guard size >= 8, size <= 32 + bytes - cursor else { return false }
            if kind == 0x32 {
                guard size >= 24, try u32(cursor + 8) == 1, try u32(cursor + 12) == 0x000e0000 else { return false }
                found = true
            }
            cursor += size
        }
        return found && cursor == 32 + bytes
    }
}
private extension Sequence where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
