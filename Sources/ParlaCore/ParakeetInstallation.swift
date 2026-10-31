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
        case .unsupportedHost: return "Parakeet requires arm64 and macOS 14 or later; host eligibility is unavailable or unsupported."
        case .reconciling: return "Parakeet startup records are still being reconciled. Start a new action after settlement."
        case .releaseIntegrity: return "Install unavailable: reviewed payload SHA256 evidence for all 21 pinned files is missing."
        case .terms: return "Install unavailable: selected-artifact terms and delivered attribution approval are missing."
        case .trustedProduct: return "Parakeet unavailable: independent G3 helper product is missing or failed trust checks."
        case .configuration: return "Repair and save recognition settings before using Parakeet controls."
        case .closed: return "Parakeet admission is closed for quit or restart."
        case .busy: return "Parakeet work is still owned. Wait for its actual exit."
        case .protectedInstallation: return "Installation is protected by saved global/profile references or live uses."
        case .storage: return "Parakeet tracking is unavailable. Assets are preserved; no automatic repair."
        case .interrupted: return "Parakeet work was interrupted. Retry explicitly after ownership verification."
        case .absent: return "No verified Parakeet installation. Install must be explicit."
        case .needsPreparation: return "Installed, not prepared. Run an explicit load check when prerequisites are available."
        case .integrity: return "Parakeet file membership, size, identity or full release hash did not verify."
        case .transport: return "Pinned Parakeet transfer failed its bounded response checks."
        case .revoked: return "Parakeet action was canceled. Owned work must finish stopping."
        case .deadline: return "Parakeet deadline expired. Waiting for actual worker exit."
        case .loadCheck: return "Parakeet load check did not complete with clean exit and joined IO."
        }
    }
}
