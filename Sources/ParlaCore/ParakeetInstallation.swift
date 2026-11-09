import Foundation
import CryptoKit

/// Release evidence is independent of the helper's provisional mixed-hash guard.
/// These inputs come from product code, never Settings, URLs or disk receipts.
public struct ParakeetDataRelease: Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public let path: String
        public let bytes: Int
        public let payloadSHA256: String
        public init(path: String, bytes: Int, payloadSHA256: String) {
            self.path = path; self.bytes = bytes; self.payloadSHA256 = payloadSHA256
        }
    }
    public let files: [File]
    public let reviewEvidenceSHA256: String
    public let id: String
    public var bytes: Int { files.reduce(0) { $0 + $1.bytes } }
    public static let repository = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
    public static let payloadLimit = 2 * ParakeetModelManifest.declaredBytes
    public static let recordLimit = 65_536
    public static let metadataLimit = 1_048_576

    public init(files: [File], reviewEvidenceSHA256: String) throws {
        try self.init(files: files, reviewEvidenceSHA256: reviewEvidenceSHA256, pinnedSizes: true)
    }
    // Only @testable source tests can supply tiny payloads; not a production input provider.
    init(files: [File], reviewEvidenceSHA256: String, pinnedSizes: Bool) throws {
        let pinned = ParakeetModelManifest.entries
        guard files.count == 21, Set(files.map(\.path)) == Set(pinned.map(\.path)),
              Self.isSHA256(reviewEvidenceSHA256), files.allSatisfy({ file in
                  file.bytes > 0 && file.bytes <= ParakeetModelManifest.declaredBytes && Self.isSHA256(file.payloadSHA256)
                    && (!pinnedSizes || pinned.contains { $0.path == file.path && $0.bytes == file.bytes
                        && ($0.kind != .payloadSHA256 || $0.digest == file.payloadSHA256) })
              }), files.reduce(Int64(0), { $0 + Int64($1.bytes) }) <= ParakeetModelManifest.declaredBytes else {
            throw ParakeetInstallationRefusal.releaseIntegrity
        }
        self.files = files.sorted { $0.path < $1.path }; self.reviewEvidenceSHA256 = reviewEvidenceSHA256
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var binding = Data((Self.repository + "\n" + ParakeetWire.modelRevision + "\n" + ParakeetWire.model + "\n" + reviewEvidenceSHA256 + "\n").utf8)
        binding.append(try encoder.encode(self.files)); id = Self.sha256(binding)
    }
    public func request(for file: File) throws -> URLRequest {
        guard files.contains(file), let url = URL(string: "https://huggingface.co/" + Self.repository + "/resolve/" + ParakeetWire.modelRevision + "/" + file.path) else {
            throw ParakeetInstallationRefusal.releaseIntegrity
        }
        var request = URLRequest(url: url); request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }
    public static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// An independently reviewed applicability/attribution decision for this release.
/// A license string or a receipt asserting approval is not approval evidence.
public struct ParakeetTermsApproval: Equatable, Sendable {
    public let releaseID: String
    public let decisionSHA256: String
    public let deliveredNoticesSHA256: String
    public init(releaseID: String, decisionSHA256: String, deliveredNoticesSHA256: String) throws {
        guard [releaseID, decisionSHA256, deliveredNoticesSHA256].allSatisfy(ParakeetDataRelease.isSHA256) else {
            throw ParakeetInstallationRefusal.terms
        }
        self.releaseID = releaseID; self.decisionSHA256 = decisionSHA256; self.deliveredNoticesSHA256 = deliveredNoticesSHA256
    }
}

public struct ParakeetPreparedScope: Codable, Equatable, Sendable {
    public let releaseID: String
    public let installation: UUID
    public let product: ParakeetProductIdentity
    public let os: String
    public let compute: String
    public init(releaseID: String, installation: UUID, product: ParakeetProductIdentity, os: String) {
        self.releaseID = releaseID; self.installation = installation; self.product = product; self.os = os
        compute = ParakeetWire.Identity(helperBuild: product.helperSHA256, osScope: os).compute
    }
}

public enum ParakeetInstallationRefusal: String, Error, Sendable {
    case releaseIntegrity, terms, trustedProduct, configuration, closed, busy, protectedInstallation
    case storage, interrupted, absent, needsPreparation, integrity, transport, revoked, deadline, loadCheck
    case unsupportedHost, reconciling
    public var message: String {
        switch self {
        case .unsupportedHost: return "Parakeet needs an Apple silicon Mac with macOS 14 or later."
        case .reconciling: return "Parakeet is starting up. Try again in a moment."
        case .releaseIntegrity: return "Parakeet isn’t available in this version of Parla."
        case .terms: return "Parakeet isn’t available in this version of Parla."
        case .trustedProduct: return "Parakeet isn’t available in this version of Parla."
        case .configuration: return "Save your speech settings first."
        case .closed: return "Parla is quitting."
        case .busy: return "Parakeet is busy. Try again in a moment."
        case .protectedInstallation: return "Parakeet is in use by your settings or a profile, so it can’t be deleted."
        case .storage: return "Parakeet’s files can’t be checked right now."
        case .interrupted: return "Parakeet setup was interrupted. Click Retry."
        case .absent: return "Parakeet isn’t installed. Click Install."
        case .needsPreparation: return "Parakeet is installed. Click Prepare to finish setup."
        case .integrity: return "Parakeet’s files are damaged. Delete and install again."
        case .transport: return "Parakeet download failed. Click Retry."
        case .revoked: return "Canceled."
        case .deadline: return "Parakeet took too long. Try again."
        case .loadCheck: return "Parakeet couldn’t load. Try Prepare again."
        }
    }
}
