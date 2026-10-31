import Foundation
import Testing
@testable import ParakeetHelper

struct WireTests {
    @Test func canonicalVectorsAndClosedSchemaExerciseCodec() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixtures/parakeet-helper-v1.json"))) as! [String: Any]
        let vectors = value["vectors"] as! [[String: Any]]
        for vector in vectors {
            let hex = vector["hex"] as! String
            let bytes = Data(stride(from: 0, to: hex.count, by: 2).map { i in UInt8(hex.dropFirst(i).prefix(2), radix: 16)! })
            if vector["reject"] as? Bool == true { #expect(throws: (any Error).self) { try ParakeetWire.parseHeader(bytes.prefix(8)) } }
            else {
                let (kind, count) = try ParakeetWire.parseHeader(bytes.prefix(8))
                #expect(count == bytes.count - 8)
                if kind == .pcm {
                    let samples = try ParakeetWire.samples(bytes.dropFirst(8))
                    #expect(samples == [0, -0.5, 1]); #expect(try ParakeetWire.pcm(samples[...]) == bytes)
                } else { #expect(kind == .end) }
            }
        }
        let id = ParakeetWire.Identity(helperBuild: String(repeating: "a", count: 64), osScope: "fixture")
        let bytes = try ParakeetWire.encode(.init(identity: id), kind: .hello)
        #expect(try ParakeetWire.decode(bytes.dropFirst(8), kind: .hello).identity == id)
        var object = try JSONSerialization.jsonObject(with: bytes.dropFirst(8)) as! [String: Any]
        object["unexpected"] = true
        #expect(throws: (any Error).self) { try ParakeetWire.decode(JSONSerialization.data(withJSONObject: object), kind: .hello) }
        #expect(ParakeetModelManifest.entries.count == 21)
        #expect(ParakeetModelManifest.entries.reduce(0) { $0 + $1.bytes } == 335_745_501)
        #expect(ParakeetModelManifest.entries.filter { $0.kind == .payloadSHA256 }.count == 12)
        #expect(!ParakeetWire.filters.contains("hi")); #expect(!ParakeetWire.filters.contains("bs"))
    }
}
