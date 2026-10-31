import Foundation

/// Strict, bounded JSON for the offline corpus contract. No Foundation object
/// bridge: decoded duplicate keys (including escaped spellings) cannot vanish.
indirect enum EvalCorpusJSON {
    case object([String: EvalCorpusJSON]), array([EvalCorpusJSON]), string(String)
    case number(String), bool(Bool), null

    static func parse(_ data: Data) throws -> EvalCorpusJSON {
        var parser = Parser(bytes: Array(data))
        let value = try parser.value(depth: 0)
        parser.space()
        guard parser.index == parser.bytes.count else { throw EvalCorpusError.json }
        return value
    }

    func object(_ keys: String) throws -> [String: EvalCorpusJSON] {
        guard case .object(let object) = self,
              Set(object.keys) == Set(keys.split(separator: " ").map(String.init)) else {
            throw EvalCorpusError.schema
        }
        return object
    }
    func array(limit: Int) throws -> [EvalCorpusJSON] {
        guard case .array(let values) = self, values.count <= limit else { throw EvalCorpusError.bounds }
        return values
    }
    func string() throws -> String {
        guard case .string(let value) = self else { throw EvalCorpusError.schema }
        return value
    }
    func integer(max: Int = 253_402_300_799) throws -> Int {
        guard case .number(let raw) = self, !raw.isEmpty,
              raw.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int(raw), value <= max else {
            throw EvalCorpusError.schema
        }
        return value
    }
    func real() throws -> Double {
        // A negative spelling can underflow to signed zero during conversion.
        guard case .number(let raw) = self, !raw.hasPrefix("-"),
              let value = Double(raw), value.isFinite, value >= 0 else {
            throw EvalCorpusError.schema
        }
        return value
    }
    func attested() throws {
        guard case .bool(true) = self else { throw EvalCorpusError.attestation }
    }
    var isNull: Bool { if case .null = self { return true }; return false }
    func id() throws -> String {
        let value = try string()
        guard (1...64).contains(value.utf8.count), value.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }) else { throw EvalCorpusError.schema }
        return value
    }
    func hash() throws -> String {
        let value = try string()
        guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw EvalCorpusError.binding
        }
        return value
    }
    func choice(_ allowed: String) throws -> String {
        let value = try string()
        guard allowed.split(separator: " ").contains(Substring(value)) else { throw EvalCorpusError.schema }
        return value
    }
    func ids(limit: Int) throws -> [String] {
        let values = try array(limit: limit).map { try $0.id() }
        guard Set(values).count == values.count else { throw EvalCorpusError.duplicate }
        return values
    }
    func choices(_ allowed: String, limit: Int) throws -> Set<String> {
        let values = try array(limit: limit).map { try $0.choice(allowed) }
        guard Set(values).count == values.count else { throw EvalCorpusError.duplicate }
        return Set(values)
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        mutating func space() {
            while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }
        mutating func consume(_ byte: UInt8) -> Bool {
            space()
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }
        mutating func text() throws -> String {
            space()
            let start = index
            guard index < bytes.count, bytes[index] == 34 else { throw EvalCorpusError.json }
            index += 1
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 {
                    guard let value = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) else {
                        throw EvalCorpusError.json
                    }
                    return value
                }
                guard byte >= 32 else { throw EvalCorpusError.json }
                if byte == 92 {
                    guard index < bytes.count else { throw EvalCorpusError.json }
                    index += 1
                }
            }
            throw EvalCorpusError.json
        }
        mutating func value(depth: Int) throws -> EvalCorpusJSON {
            space()
            guard index < bytes.count else { throw EvalCorpusError.json }
            switch bytes[index] {
            case 123:
                guard depth < 32 else { throw EvalCorpusError.bounds }
                index += 1
                var values: [String: EvalCorpusJSON] = [:]
                if consume(125) { return .object(values) }
                repeat {
                    let key = try text()
                    guard values[key] == nil else { throw EvalCorpusError.duplicate }
                    guard consume(58) else { throw EvalCorpusError.json }
                    values[key] = try value(depth: depth + 1)
                    if consume(125) { return .object(values) }
                    guard consume(44) else { throw EvalCorpusError.json }
                } while true
            case 91:
                guard depth < 32 else { throw EvalCorpusError.bounds }
                index += 1
                var values: [EvalCorpusJSON] = []
                if consume(93) { return .array(values) }
                repeat {
                    values.append(try value(depth: depth + 1))
                    if consume(93) { return .array(values) }
                    guard consume(44) else { throw EvalCorpusError.json }
                } while true
            case 34: return .string(try text())
            case 116: try literal("true"); return .bool(true)
            case 102: try literal("false"); return .bool(false)
            case 110: try literal("null"); return .null
            default:
                let start = index
                _ = consume(45)
                guard index < bytes.count else { throw EvalCorpusError.json }
                if bytes[index] == 48 { index += 1 }
                else {
                    guard (49...57).contains(bytes[index]) else { throw EvalCorpusError.json }
                    digits()
                }
                if index < bytes.count, bytes[index] == 46 {
                    index += 1
                    let before = index; digits()
                    guard index > before else { throw EvalCorpusError.json }
                }
                if index < bytes.count, bytes[index] == 101 || bytes[index] == 69 {
                    index += 1
                    if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 { index += 1 }
                    let before = index; digits()
                    guard index > before else { throw EvalCorpusError.json }
                }
                return .number(String(decoding: bytes[start..<index], as: UTF8.self))
            }
        }
        mutating func digits() {
            while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
        }
        mutating func literal(_ value: String) throws {
            let token = Array(value.utf8)
            guard bytes.count - index >= token.count, Array(bytes[index..<(index + token.count)]) == token else {
                throw EvalCorpusError.json
            }
            index += token.count
        }
    }
}

extension Dictionary where Key == String, Value == EvalCorpusJSON {
    func field(_ key: String) throws -> EvalCorpusJSON {
        guard let value = self[key] else { throw EvalCorpusError.schema }
        return value
    }
}
