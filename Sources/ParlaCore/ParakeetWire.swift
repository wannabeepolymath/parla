import Foundation

/// Minimal transport values. Both packages use these exact codec bytes; the canonical
/// contract and vectors are fixtures/parakeet-helper-v1.json, not a Swift object ABI.
public enum ParakeetWire {
    public static let sdk = "503b4bd1bbf7220882de39fe8ae6716aae4132da"
    public static let modelRevision = "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe"
    public static let model = "tdt-0.6b-v3-int4"
    public static let manifest = "ce1b4b64fc5616121f3a888b0e760f17e912fa550fbfb0d8e5379b015b793b8f"
    public static let filters = Set("en es fr de bg hr cs da nl et fi el hu it lv lt mt pl pt ro sk sl sv ru uk".split(separator: " ").map(String.init))
    public static let maximumSamples = 9_600_000
    public static let maximumPCM = 65_536
    public static let maximumRecord = 1_048_576
    public enum Failure: Error, Sendable { case malformed, bounds, identity, order, io, unavailable, deadline }
    public enum Kind: UInt8, Sendable { case hello = 1, request, pcm, end, terminal, cancel, close }
    public enum Mode: String, Codable, Sendable { case prepareLoad, recognizeBatch }
    public enum Code: String, Codable, Sendable { case completed, failed, canceled }
    public struct Identity: Codable, Equatable, Sendable {
        public let protocolVersion: Int
        public let adapterRevision: Int
        public let sdk: String
        public let helperBuild: String
        public let model: String
        public let modelRevision: String
        public let manifest: String
        public let verification: String
        public let compute: String
        public let osScope: String
        public let nonce: UUID
        public let request: UUID
        public let session: UUID
        public init(helperBuild: String, osScope: String, nonce: UUID = UUID(), request: UUID = UUID(), session: UUID = UUID()) {
            protocolVersion = 1; adapterRevision = 1; sdk = ParakeetWire.sdk
            self.helperBuild = helperBuild; model = ParakeetWire.model; modelRevision = ParakeetWire.modelRevision
            manifest = ParakeetWire.manifest; verification = "provisional-mixed-metadata-v1"
            compute = "cpuAndNeuralEngine-lowPrecision-parallel1-int4-noEncoderOverride"
            self.osScope = osScope; self.nonce = nonce; self.request = request; self.session = session
        }
        public func validate() throws {
            let expected = Identity(helperBuild: helperBuild, osScope: osScope, nonce: nonce, request: request, session: session)
            guard self == expected, helperBuild.utf8.count == 64,
                  helperBuild.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  !osScope.isEmpty, osScope.utf8.count <= 128,
                  osScope.utf8.allSatisfy({ (32...126).contains($0) }) else { throw Failure.identity }
        }
    }
    public struct Record: Codable, Equatable, Sendable {
        public let identity: Identity
        public var mode: Mode?
        public var directory: String?
        public var sampleCount: Int?
        public var filter: String?
        public var code: Code?
        public var text: String?
        public init(identity: Identity, mode: Mode? = nil, directory: String? = nil, sampleCount: Int? = nil,
                    filter: String? = nil, code: Code? = nil, text: String? = nil) {
            self.identity = identity; self.mode = mode; self.directory = directory; self.sampleCount = sampleCount
            self.filter = filter; self.code = code; self.text = text
        }
        public func validate(_ kind: Kind) throws {
            try identity.validate()
            switch kind {
            case .request:
                guard let mode, let directory, directory.hasPrefix("/"), directory.utf8.count <= 4096,
                      !directory.contains("\0"), !directory.split(separator: "/").contains(".."),
                      let sampleCount, (0...maximumSamples).contains(sampleCount),
                      mode != .prepareLoad || sampleCount == 0,
                      filter.map({ filters.contains($0) }) ?? true, code == nil, text == nil else { throw Failure.malformed }
            case .terminal:
                guard let code, mode == nil, directory == nil, sampleCount == nil, filter == nil,
                      code == .completed ? text != nil : text == nil,
                      (text?.utf8.count ?? 0) <= maximumRecord else { throw Failure.malformed }
            case .hello, .cancel, .close:
                guard mode == nil, directory == nil, sampleCount == nil, filter == nil, code == nil, text == nil else { throw Failure.malformed }
            case .pcm, .end: throw Failure.order
            }
        }
    }
    public static func header(_ kind: Kind, count: Int) throws -> Data {
        let limit = kind == .pcm ? maximumPCM : kind == .end ? 0 : maximumRecord
        guard count >= 0, count <= limit, kind != .pcm || count > 0 && count % 4 == 0 else { throw Failure.bounds }
        let n = UInt32(count)
        return Data([0x50, 0x4b, 1, kind.rawValue, UInt8(n & 255), UInt8((n >> 8) & 255), UInt8((n >> 16) & 255), UInt8(n >> 24)])
    }
    /// Check the closed kind and length before allocating a payload buffer.
    public static func parseHeader(_ bytes: Data) throws -> (Kind, Int) {
        guard bytes.count == 8 else { throw Failure.malformed }
        let b = Array(bytes)
        guard b[0...2].elementsEqual([0x50, 0x4b, 1]), let kind = Kind(rawValue: b[3]) else { throw Failure.malformed }
        let count = Int(UInt32(b[4]) | UInt32(b[5]) << 8 | UInt32(b[6]) << 16 | UInt32(b[7]) << 24)
        _ = try header(kind, count: count)
        return (kind, count)
    }
    public static func encode(_ record: Record, kind: Kind) throws -> Data {
        try record.validate(kind)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(record)
        return try header(kind, count: payload.count) + payload
    }
    public static func decode(_ payload: Data, kind: Kind) throws -> Record {
        guard payload.count <= maximumRecord,
              let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let identity = object["identity"] as? [String: Any],
              Set(identity.keys) == Set(["protocolVersion", "adapterRevision", "sdk", "helperBuild", "model", "modelRevision", "manifest", "verification", "compute", "osScope", "nonce", "request", "session"]),
              Set(object.keys).isSubset(of: ["identity", "mode", "directory", "sampleCount", "filter", "code", "text"]),
              !object.values.contains(where: { $0 is NSNull }) else { throw Failure.malformed }
        let value = try JSONDecoder().decode(Record.self, from: payload)
        try value.validate(kind)
        return value
    }
    public static func pcm(_ samples: ArraySlice<Float>) throws -> Data {
        guard !samples.isEmpty, samples.count <= maximumPCM / 4,
              samples.allSatisfy({ $0.isFinite && (-1...1).contains($0) }) else { throw Failure.bounds }
        var data = try header(.pcm, count: samples.count * 4)
        for sample in samples {
            let n = sample.bitPattern
            data.append(contentsOf: [UInt8(n & 255), UInt8((n >> 8) & 255), UInt8((n >> 16) & 255), UInt8(n >> 24)])
        }
        return data
    }
    public static func samples(_ payload: Data) throws -> [Float] {
        guard !payload.isEmpty, payload.count <= maximumPCM, payload.count % 4 == 0 else { throw Failure.bounds }
        let b = Array(payload)
        return try stride(from: 0, to: b.count, by: 4).map { i in
            let n = UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
            let value = Float(bitPattern: n)
            guard value.isFinite, (-1...1).contains(value) else { throw Failure.bounds }
            return value
        }
    }
}

/// One pending read/write per direction; close must wake IO, join retires callbacks.
public protocol ParakeetChannel: Sendable {
    func read(upTo count: Int) async throws -> Data
    func write(_ data: Data) async throws
    func close() async
    func join() async
}
public extension ParakeetWire {
    static func readExactly(_ count: Int, from channel: any ParakeetChannel, allowEOF: Bool = false) async throws -> Data? {
        guard count >= 0, count <= maximumRecord else { throw Failure.bounds }
        var result = Data()
        while result.count < count {
            let part = try await channel.read(upTo: min(maximumPCM, count - result.count))
            guard !part.isEmpty else {
                if allowEOF && result.isEmpty { return nil }
                throw Failure.malformed
            }
            guard part.count <= count - result.count else { throw Failure.bounds }
            result.append(part)
        }
        return result
    }
    static func readFrame(from channel: any ParakeetChannel) async throws -> (Kind, Data)? {
        guard let bytes = try await readExactly(8, from: channel, allowEOF: true) else { return nil }
        let (kind, count) = try parseHeader(bytes)
        return (kind, try await readExactly(count, from: channel) ?? Data())
    }
}
