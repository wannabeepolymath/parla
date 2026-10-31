import XCTest
import Foundation
@testable import ParlaCore

final class ParakeetWireTests: XCTestCase {
    func testCanonicalVectorsAndNonemptyMetadataAreUsedByHostCodec() async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixtures/parakeet-helper-v1.json"))) as! [String: Any]
        for vector in object["vectors"] as! [[String: Any]] {
            let hex = vector["hex"] as! String
            let data = Data(stride(from: 0, to: hex.count, by: 2).map { UInt8(hex.dropFirst($0).prefix(2), radix: 16)! })
            if vector["reject"] as? Bool == true { XCTAssertThrowsError(try ParakeetWire.parseHeader(data.prefix(8))) }
            else {
                let (kind, count) = try ParakeetWire.parseHeader(data.prefix(8))
                XCTAssertEqual(count, data.count - 8)
                if kind == .pcm {
                    let samples = try ParakeetWire.samples(data.dropFirst(8))
                    XCTAssertEqual(samples, [0, -0.5, 1]); XCTAssertEqual(try ParakeetWire.pcm(samples[...]), data)
                }
                let pipe = ParakeetTestPipe(fragment: 1); await pipe.feed(data); await pipe.close()
                let frame = try await ParakeetWire.readFrame(from: pipe); XCTAssertEqual(frame?.0, kind)
                let eof = try await ParakeetWire.readFrame(from: pipe); XCTAssertNil(eof)
            }
        }
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixtures/parakeet-model-metadata-v1.json"))) as! [String: Any]
        XCTAssertEqual(metadata["metadata_manifest_sha256"] as? String, ParakeetModelManifest.metadataID)
        XCTAssertEqual(ParakeetModelManifest.entries.count, 21)
        XCTAssertEqual(ParakeetModelManifest.entries.reduce(0) { $0 + $1.bytes }, 335_745_501)
        XCTAssertEqual(ParakeetModelManifest.entries.filter { $0.kind == .payloadSHA256 }.count, 12)
        XCTAssertEqual(ParakeetModelManifest.entries.filter { $0.kind == .gitBlobSHA1 }.count, 9)
        XCTAssertFalse(ParakeetModelManifest.entries.contains { $0.path.contains("Ctc") })
    }
    func testRealTrustDriverRejectsMalformedCodeResourcesAndUnsupportedHost() throws {
        let rig = ParakeetTestRig()
        let positive = try ParakeetTrust.admit(expected: rig.identity, app: URL(fileURLWithPath: "/fixed/Parla.app"), bottom: rig.trust)
        XCTAssertEqual(positive.executable.path, "/fixed/Parla.app/Contents/Helpers/ParlaParakeetHelper.bundle/Contents/MacOS/ParlaParakeetHelper")
        var bottom = rig.trust; bottom.host = { throw ParakeetRefusal.unsupportedHost }
        XCTAssertThrowsError(try ParakeetTrust.admit(expected: rig.identity, bottom: bottom))
        bottom = rig.trust; let read = bottom.read
        bottom.read = { url, limit in url.lastPathComponent == "fixture" ? Data("mismatch".utf8) : try read(url, limit) }
        XCTAssertThrowsError(try ParakeetTrust.admit(expected: rig.identity, bottom: bottom))
        bottom = rig.trust; bottom.signature = { _, _ in throw ParakeetRefusal.codeIdentity }
        XCTAssertThrowsError(try ParakeetTrust.admit(expected: rig.identity, bottom: bottom))
        bottom = rig.trust; bottom.read = { url, limit in url.lastPathComponent == "ParlaParakeetHelper" ? Data([0]) : try read(url, limit) }
        XCTAssertThrowsError(try ParakeetTrust.admit(expected: rig.identity, bottom: bottom))
    }
    func testG3ObservedDescriptorAndHelperCannotReplaceIndependentExpectedIdentity() throws {
        let rig = ParakeetTestRig()
        var binary = rig.binary; binary.append(Data("synthetic changed signed code".utf8))
        let replacement = ParakeetProductIdentity(protocolVersion: 1, adapterRevision: 1, sdk: ParakeetWire.sdk,
            helperSHA256: ParakeetDataRelease.sha256(binary), sourceSHA256: String(repeating: "e", count: 64),
            resources: rig.identity.resources, team: "OTHERTESTTEAM")
        let bottom = ParakeetTrustBottom(host: {}, read: { url, _ in
            switch url.lastPathComponent {
            case "parakeet-product.json": return try JSONEncoder().encode(replacement)
            case "ParlaParakeetHelper": return binary
            case "fixture": return rig.resource
            default: throw ParakeetRefusal.codeIdentity
            }
        }, signature: { _, team in XCTAssertEqual(team, replacement.team) })
        XCTAssertThrowsError(try ParakeetTrust.admit(expected: rig.identity, bottom: bottom)) {
            XCTAssertEqual($0 as? ParakeetRefusal, .codeIdentity)
        }
        // The replacement is structurally admissible with independently supplied
        // material. Its writable descriptor cannot grant that material itself.
        XCTAssertEqual(try ParakeetTrust.admit(expected: replacement, bottom: bottom).identity, replacement)
    }
}
