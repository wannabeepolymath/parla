// CANDIDATE ONLY: UNCOMPILED / UNREVIEWED / NONEXECUTED.
// Install later as ONE Tests/ParlaCoreTests file. No other source edits.
import AppKit
import CryptoKit
import Darwin
import XCTest
@testable import ParlaCore

private enum B25Failure: String, Error {
    case controls, transport, protocolMismatch, nativeRefusal, payloadMismatch
    case settlementTimeout, restorationMismatch, receiptMismatch, timingWindow
    case shutdownMismatch, oversizedMismatch, resultWrite
}
private func b25Milliseconds() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
}
// BEGIN B25_PATH_VALIDATOR_V1
// Duplicate verbatim in the two private candidates; extract for controls-only review.
private enum B25PhysicalPath {
    static let draft = "/private/var/folders/vp/_gvcxwbx3rg9cz0193_n4kr00000gn/T/parla-owned-ocr-20261030-0av9ol73/b25-private-native-draft"

    static func isOwnedLeaf(_ info: stat, directory: Bool) -> Bool {
        guard info.st_uid == Darwin.getuid(),
              info.st_mode & mode_t(S_IFMT) == mode_t(directory ? S_IFDIR : S_IFREG)
        else { return false }
        return !directory || info.st_mode & mode_t(0o7777) == mode_t(0o700)
    }

    static func matches(_ raw: String, expected: String, directory: Bool) -> Bool {
        guard raw == expected,
              URL(fileURLWithPath: raw, isDirectory: directory).path == expected,
              let physical = raw.withCString({ Darwin.realpath($0, nil) })
        else { return false }
        defer { Darwin.free(physical) }
        guard String(validatingUTF8: physical) == expected else { return false }
        var info = stat()
        return raw.withCString({ Darwin.lstat($0, &info) }) == 0
            && isOwnedLeaf(info, directory: directory)
    }

    static func root(_ raw: String, runID: String) -> URL? {
        guard matches(raw, expected: draft + "/baseline-native-run-" + runID, directory: true)
        else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    static func consumer(_ raw: String, root: URL) -> Bool {
        matches(raw, expected: root.path + "/OwnedPrivatePasteboardConsumer", directory: false)
    }
}
// END B25_PATH_VALIDATOR_V1
// BEGIN B25_OWNER_CONTROLS_V1
private struct B25Controls: Sendable {
    let runID: String, board: String, nonce: String, consumer: String, consumerHash: String
    let root: URL
    let input: Int32, output: Int32
    static func load(_ e: [String: String]) throws -> Self {
        func value(_ key: String) throws -> String {
            guard let v = e[key], !v.isEmpty else { throw B25Failure.controls }; return v
        }
        guard e["PARLA_RUN_OWNED_B25_BASELINE_NATIVE"] == "1", e["B25_PRIVATE_NATIVE"] == nil,
              e["PARLA_RUN_OWNED_B25_NATIVE"] == nil else { throw B25Failure.controls }
        let run = try value("B25_RUN_ID"), nonce = try value("B25_NONCE")
        guard let uuid = UUID(uuidString: run), uuid.uuidString.lowercased() == run,
              nonce.count == 64, nonce.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw B25Failure.controls }
        let board = try value("B25_BOARD_NAME")
        // An exact allowlist of ONE identity, never a standard-name fallback.
        guard board == "com.parla.b25.private.\(run).\(nonce)" else { throw B25Failure.controls }
        let consumer = try value("B25_CONSUMER_EXECUTABLE"), hash = try value("B25_CONSUMER_SHA256")
        guard let root = B25PhysicalPath.root(try value("B25_RESULT_ROOT"), runID: run),
              B25PhysicalPath.consumer(consumer, root: root),
              FileManager.default.isExecutableFile(atPath: consumer),
              let input = Int32(try value("B25_OWNER_READ_FD")), input >= 3,
              let output = Int32(try value("B25_OWNER_WRITE_FD")), output >= 3, input != output
        else { throw B25Failure.controls }
        let executable = try Data(contentsOf: URL(fileURLWithPath: consumer), options: .mappedIfSafe)
        guard executable.count <= 32 * 1024 * 1024,
              SHA256.hash(data: executable).map({ String(format: "%02x", $0) }).joined() == hash
        else { throw B25Failure.controls }
        return Self(runID: run, board: board, nonce: nonce, consumer: consumer,
                    consumerHash: hash, root: root, input: input, output: output)
    }
}
// END B25_OWNER_CONTROLS_V1
// BEGIN B25_BASELINE_V1 — deliberately duplicated in these two closed fixtures.
private enum B25CodecFailure: Error { case invalid }
private func b25Check(_ value: Bool) throws { if !value { throw B25CodecFailure.invalid } }
private func b25Hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
private struct B25Entry: Codable, Equatable, Sendable {
    let t: String, n: Int, b: Int, s: String
}
private struct B25Baseline: Codable, Equatable, Sendable {
    let v: Int, role: String, c: Int, clear: Int, pub: Int, before: Int, after: Int
    let items: [[B25Entry]], digest: String
    static let extra = "f0e5bb85826793914cb31551f0d6aab6e5df33a818a268c5747465b55ee837a8"
    static func entries(_ raw: [[NSPasteboard.PasteboardType: Data]]) -> [[B25Entry]] {
        raw.map { item in item.map { type, data in
            B25Entry(t: b25Hash(Data(type.rawValue.utf8)), n: type.rawValue.utf8.count,
                     b: data.count, s: b25Hash(data))
        }.sorted { $0.t < $1.t } }
    }
    static func supplied(_ newer: Bool) -> [[NSPasteboard.PasteboardType: Data]] {
        let tag = newer ? "replacement" : "original"
        return [[.string: Data("B25 \(tag) α 😀\n".utf8),
                 .rtf: Data("{\\rtf1\\ansi B25 \(tag)}".utf8)],
                [.init("com.parla.b25.synthetic"): Data(newer ? [91,92,93] : [7,8,9]),
                 .init("com.parla.b25.empty"): Data()]]
    }
    func preimage(run: String, board: String, nonce: String) -> Data {
        var fields = ["Parla/B25/native-baseline/v1", role, run, board, nonce,
                      String(c), String(clear), String(pub), String(before), String(after), String(items.count)]
        for (index, item) in items.enumerated() {
            fields += [String(index), String(item.count)]
            for e in item { fields += [e.t, String(e.n), String(e.b), e.s] }
        }
        var bytes = Data()
        for field in fields { bytes.append(contentsOf: "\(field.utf8.count):\(field)\n".utf8) }
        return bytes
    }
    func validated(run: String, board: String, nonce: String, caseNumber: Int, expectedRole: String) throws {
        func integer(_ n: Int) -> Bool { (0...2_147_483_647).contains(n) }
        func hex(_ s: String) -> Bool { s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        try b25Check(v == 1 && c == caseNumber && (1...7).contains(c) && role == expectedRole
            && (role == "original" || role == "replacement" && c == 6))
        try b25Check([clear,pub,before,after].allSatisfy(integer) && pub == before && pub == after)
        try b25Check(items.count == 2)
        let known = Self.entries(Self.supplied(role == "replacement"))
        var names = 0, bytes = 0
        for (i,item) in items.enumerated() {
            try b25Check(item.count == (i == 0 ? 3 : 2))
            var last = ""
            for e in item {
                try b25Check(hex(e.t) && hex(e.s) && e.t > last && (1...106).contains(e.n) && (0...65_536).contains(e.b))
                names += e.n; bytes += e.b; last = e.t
            }
            for e in known[i] { try b25Check(item.contains(e)) }
            let extra = item.filter { entry in !known[i].contains { $0.t == entry.t } }
            if i == 0 {
                try b25Check(extra.count == 1 && extra[0].t == Self.extra && extra[0].n == 32
                    && (role == "original" ? extra[0].b == 26 : extra[0].b <= 65_481))
            } else { try b25Check(extra.isEmpty) }
        }
        try b25Check(names == 106 && (role == "original" ? bytes == 75 : bytes <= 65_536))
        try b25Check(hex(digest) && digest == b25Hash(preimage(run: run, board: board, nonce: nonce)))
    }
    static func make(raw: [[NSPasteboard.PasteboardType: Data]], role: String, c: Int,
                     clear: Int, pub: Int, before: Int, after: Int,
                     run: String, board: String, nonce: String) throws -> Self {
        // Supplied fidelity is checked on raw dictionaries as well as metadata.
        let known = supplied(role == "replacement")
        try b25Check(raw.count == known.count)
        for (item, values) in zip(raw,known) { for (t,d) in values { try b25Check(item[t] == d) } }
        let provisional = Self(v: 1, role: role, c: c, clear: clear, pub: pub, before: before,
                               after: after, items: entries(raw), digest: "")
        let result = Self(v: 1, role: role, c: c, clear: clear, pub: pub, before: before,
                          after: after, items: provisional.items,
                          digest: b25Hash(provisional.preimage(run: run, board: board, nonce: nonce)))
        try result.validated(run: run, board: board, nonce: nonce, caseNumber: c, expectedRole: role)
        return result
    }
}
private enum B25Op: String, Codable, Sendable {
    case hello, commitOriginalBaseline, readPrepared, verifyOriginal, replace, verifyReplacement, armExit, postExit, release
}
private struct B25Command: Codable, Sendable {
    let version: Int, runID: String, board: String, nonce: String
    let sequence: Int, caseNumber: Int, op: B25Op
    let notBeforeMs: Double, ownerExited: Bool
    var baseline: B25Baseline? = nil
}
private struct B25MetadataAck: Codable, Sendable {
    let version: Int, runID: String, board: String, nonce: String
    let sequence: Int, caseNumber: Int, op: B25Op
    let kind: String, accepted: Bool, digest: String, role: String, dataReads: Int
    let startMs: Double, endMs: Double
}
private struct B25NativeReply: Codable, Sendable {
    let version: Int, runID: String, board: String, nonce: String
    let sequence: Int, caseNumber: Int, op: B25Op
    let kind: String, ok: Bool, equality: Bool
    let reads: Int, changeCount: Int, itemCount: Int, representationCount: Int
    let startMs: Double, endMs: Double
    var baseline: B25Baseline? = nil
}
private enum B25Response: Codable, Sendable {
    case ack(B25MetadataAck), native(B25NativeReply)
    private enum Key: String, CodingKey { case kind }
    init(from decoder: Decoder) throws {
        let k = try decoder.container(keyedBy: Key.self).decode(String.self, forKey: .kind)
        if k == "metadataAck" { self = .ack(try B25MetadataAck(from: decoder)) }
        else if k == "native" { self = .native(try B25NativeReply(from: decoder)) }
        else { throw B25CodecFailure.invalid }
    }
    func encode(to encoder: Encoder) throws {
        switch self { case .ack(let a): try a.encode(to: encoder); case .native(let n): try n.encode(to: encoder) }
    }
}
private enum B25Schema {
    static let identity: Set<String> = ["version","runID","board","nonce","sequence","caseNumber","op"]
    static let steps: [(Int,B25Op)] = [
        (0,.hello),(1,.commitOriginalBaseline),(1,.readPrepared),(1,.verifyOriginal),
        (2,.commitOriginalBaseline),(2,.readPrepared),(2,.readPrepared),(2,.readPrepared),(2,.verifyOriginal),
        (3,.commitOriginalBaseline),(3,.readPrepared),(3,.verifyOriginal),
        (4,.commitOriginalBaseline),(4,.readPrepared),(4,.verifyOriginal),
        (5,.commitOriginalBaseline),(5,.verifyOriginal),(6,.commitOriginalBaseline),(6,.replace),(6,.verifyReplacement),
        (7,.commitOriginalBaseline),(7,.readPrepared),(8,.armExit),(8,.postExit),(8,.release)]
    static let counts = [(0,0,0),(0,0,0),(1,1,1),(6,2,5),(0,0,0),(1,1,1),(2,1,1),(3,1,1),(8,2,5),
        (0,0,0),(1,1,1),(6,2,5),(0,0,0),(1,1,1),(6,2,5),(0,0,0),(5,2,5),
        (0,0,0),(5,2,5),(10,2,5),(0,0,0),(1,1,1),(0,0,0),(5,2,5),(5,0,0)]
    static let caps = [6,8,6,6,5,10,1,5]
    static func object(_ data: Data) throws -> [String: Any] {
        // Wire values are exclusively fixed ASCII identity, enums and hex, never escaped payload.
        try b25Check(data.count < 4096 && !data.contains(10) && !data.contains(13) && !data.contains(92)
            && data.allSatisfy { $0 < 128 })
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = String(data: data, encoding: .utf8) else { throw B25CodecFailure.invalid }
        let regex = try NSRegularExpression(pattern: #""([A-Za-z][A-Za-z0-9]*)"\s*:\s*"#)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var lexical: [String:Int] = [:], actual: [String:Int] = [:]
        let integerKeys: Set<String> = ["version","sequence","caseNumber","v","c","clear","pub","before","after","n","b",
            "dataReads","reads","changeCount","itemCount","representationCount"]
        for m in regex.matches(in: text, range: range) {
            let key = (text as NSString).substring(with: m.range(at: 1)); lexical[key,default:0] += 1
            if integerKeys.contains(key) || ["notBeforeMs","startMs","endMs"].contains(key) {
                let suffix = (text as NSString).substring(from: m.range.location + m.range.length)
                let token = String(suffix.prefix { !",}] \t".contains($0) })
                try b25Check(token.utf8.count <= 32)
                if integerKeys.contains(key) {
                    guard let value = Int(token) else { throw B25CodecFailure.invalid }
                    try b25Check((0...2_147_483_647).contains(value) && String(value) == token)
                } else {
                    guard let value = Double(token) else { throw B25CodecFailure.invalid }
                    try b25Check(value.isFinite && (0...1e12).contains(value))
                }
            }
        }
        func count(_ value: Any) {
            if let o = value as? [String: Any] { for (k,v) in o { actual[k,default:0] += 1; count(v) } }
            else if let a = value as? [Any] { for v in a { count(v) } }
        }
        count(object); try b25Check(lexical == actual) // rejects duplicates before typed decoding
        return object
    }
    static func baselineShape(_ value: Any) throws {
        guard let b = value as? [String: Any] else { throw B25CodecFailure.invalid }
        try b25Check(Set(b.keys) == ["v","role","c","clear","pub","before","after","items","digest"])
        guard let items = b["items"] as? [[Any]], items.count == 2 else { throw B25CodecFailure.invalid }
        for (i,item) in items.enumerated() {
            try b25Check(item.count == (i == 0 ? 3 : 2))
            for value in item {
                guard let e = value as? [String: Any] else { throw B25CodecFailure.invalid }
                try b25Check(Set(e.keys) == ["t","n","b","s"])
            }
        }
    }
    static func command(_ data: Data) throws -> B25Command {
        let object = try object(data)
        var keys = identity.union(["notBeforeMs","ownerExited"])
        if object["op"] as? String == "commitOriginalBaseline" { keys.insert("baseline") }
        try b25Check(Set(object.keys) == keys && !object.values.contains { $0 is NSNull })
        if let b = object["baseline"] { try baselineShape(b) }
        return try JSONDecoder().decode(B25Command.self, from: data)
    }
    static func response(_ data: Data, command: B25Command, now: Double, began: Double) throws -> B25Response {
        let object = try object(data)
        let ack = command.op == .commitOriginalBaseline
        var keys = identity.union(ack ? ["kind","accepted","digest","role","dataReads","startMs","endMs"] :
            ["kind","ok","equality","reads","changeCount","itemCount","representationCount","startMs","endMs"])
        if command.op == .replace { keys.insert("baseline") }
        try b25Check(Set(object.keys) == keys && !object.values.contains { $0 is NSNull })
        if let b = object["baseline"] { try baselineShape(b) }
        let response = try JSONDecoder().decode(B25Response.self, from: data)
        func common(_ version: Int,_ run: String,_ board: String,_ nonce: String,_ seq: Int,_ c: Int,_ op: B25Op,_ start: Double,_ end: Double) throws {
            try b25Check(version == 1 && run == command.runID && board == command.board && nonce == command.nonce
                && seq == command.sequence && c == command.caseNumber && op == command.op
                && start.isFinite && end.isFinite && start >= max(0,began-100) && start <= end
                && end <= min(1e12,now+100) && end-began <= 10_000)
        }
        switch response {
        case .ack(let a):
            try common(a.version,a.runID,a.board,a.nonce,a.sequence,a.caseNumber,a.op,a.startMs,a.endMs)
            try b25Check(ack && a.kind == "metadataAck" && a.dataReads == 0 && a.role == "original" && a.digest == command.baseline?.digest)
        case .native(let n):
            try common(n.version,n.runID,n.board,n.nonce,n.sequence,n.caseNumber,n.op,n.startMs,n.endMs)
            let cap = command.caseNumber == 0 ? 0 : caps[command.caseNumber-1]
            try b25Check(!ack && n.kind == "native" && (0...cap).contains(n.reads)
                && (0...2_147_483_647).contains(n.changeCount) && (0...2).contains(n.itemCount) && (0...5).contains(n.representationCount))
            if command.op == .replace {
                guard let b = n.baseline else { throw B25CodecFailure.invalid }
                try b.validated(run: command.runID, board: command.board, nonce: command.nonce, caseNumber: 6, expectedRole: "replacement")
                try b25Check(b.pub == n.changeCount)
            }
        }
        return response
    }
}
// END B25_BASELINE_V1

// The executor of this actor owns only inherited IPC descriptors. All blocking
// poll/read/write is off MainActor. No Process, run(), waitUntilExit(), or launch.
private actor B25Wire {
    let controls: B25Controls
    private var sequence = 0, sentBytes = 0, receivedBytes = 0
    init(_ controls: B25Controls) { self.controls = controls }
    func exchange(_ op: B25Op, caseNumber: Int, notBeforeMs: Double = 0, baseline: B25Baseline? = nil) throws -> B25Response {
        sequence += 1
        try b25Check(sequence <= 23 && B25Schema.steps[sequence-1].0 == caseNumber && B25Schema.steps[sequence-1].1 == op)
        let began = b25Milliseconds()
        let command = B25Command(version: 1, runID: controls.runID, board: controls.board,
            nonce: controls.nonce, sequence: sequence, caseNumber: caseNumber, op: op,
            notBeforeMs: notBeforeMs, ownerExited: false, baseline: baseline)
        var bytes = try JSONEncoder().encode(command); bytes.append(10)
        sentBytes += bytes.count
        guard bytes.count <= 4096 && sentBytes <= 94_208 else { throw B25Failure.transport }
        // One absolute budget for write AND response, including consumer delay.
        let deadline = b25Milliseconds() + 10_000
        func ready(_ fd: Int32, _ events: Int16) throws {
            let remaining = deadline - b25Milliseconds()
            guard remaining > 0 else { throw B25Failure.transport }
            var entry = pollfd(fd: fd, events: events, revents: 0)
            guard Darwin.poll(&entry, 1, Int32(min(10_000, remaining.rounded(.up)))) > 0,
                  entry.revents & Int16(POLLERR | POLLNVAL) == 0,
                  entry.revents & events != 0 else { throw B25Failure.transport }
        }
        var offset = 0
        while offset < bytes.count {
            try ready(controls.output, Int16(POLLOUT))
            let sent = bytes.withUnsafeBytes { raw in
                Darwin.write(controls.output, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            guard sent > 0 else { throw B25Failure.transport }; offset += sent
        }
        var line = Data()
        while line.count < 4096 {
            try ready(controls.input, Int16(POLLIN))
            var byte: UInt8 = 0
            guard Darwin.read(controls.input, &byte, 1) == 1 else { throw B25Failure.transport }
            receivedBytes += 1
            guard receivedBytes <= 94_208 else { throw B25Failure.transport }
            if byte == 10 { break }; line.append(byte)
        }
        guard line.count < 4096 else { throw B25Failure.transport }
        return try B25Schema.response(line, command: command, now: b25Milliseconds(), began: began)
    }
    func close() { _ = Darwin.close(controls.input); _ = Darwin.close(controls.output) }
}
private struct B25CaseObservation: Codable {
    let number: Int, postMarkers: Int, preparedReadCommands: Int, consumerDataReads: Int
    let firstReadOffsetMs: Double?, lastReadOffsetMs: Double?
    let eligibleFulfillments: Int, ignoredFulfillments: Int, reportedFulfillmentCompletions: Int, supplyFailures: Int
    let receiptObserved: Bool, requestedDelayMs: Double, elapsedMs: Double, maximumOverrunMs: Double
    let end: DiagnosticClipboard.End?, restore: DiagnosticClipboard.Restore, receipt: DiagnosticClipboard.Receipt
    let delivery: DiagnosticDelivery, shutdownReplies: Int, shutdownTrueReplies: Int
    let snapshotEqual: Bool, changeCountUnchanged: Bool
}
private struct B25OwnerReceipt: Codable {
    let schema: Int, outcome: String, failure: B25FailureCode?
    let completedCases: [B25CaseObservation]
    let ipc: [B25Response], activeEvidence: DiagnosticClipboard?, activeCase: Int
    let shutdownReplies: [Bool]
    let activeCallBeforeMs: Double?, activeCallAfterMs: Double?, activePostMarkers: Int
    let activeAccepted: Bool?, activeInitialCount: Int?, currentCount: Int
    let pendingLease: Bool, restoreFailed: Bool, unresolvedOwnership: Bool
    let ramSnapshotRetainedUntilExit: Bool, standaloneLifetimePass: Bool
}
private struct B25FailureCode: Codable { let code: String }

@MainActor private final class B25Session {
    typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]
    let controls: B25Controls, wire: B25Wire, board: NSPasteboard
    var delivery: ClipboardDelivery
    var observations: [B25CaseObservation] = []
    var ipc: [B25Response] = [], activeCase = 0, boardVerified = false
    var originals: [Snapshot] = [] // synthetic only; never discard on a failure
    var baselines: [Int:B25Baseline] = [:]
    var retainedReplacement: Snapshot? // also retained with failedOwners on first nonpositive
    var fixtureDataReads = 0
    var activeStore: DiagnosticStore?
    var activeCallBeforeMs: Double?, activeCallAfterMs: Double?, activeAccepted: Bool?, activeInitialCount: Int?
    var activePostMarkers = 0
    var shutdownReplies: [Bool] = []
    var started = b25Milliseconds()
    static var failedOwners: [B25Session] = [] // test-only retention, no production override
    static func seed(_ newer: Bool = false) -> Snapshot {
        let tag = newer ? "replacement" : "original"
        return [
            [.string: Data("B25 \(tag) α 😀\n".utf8),
             .rtf: Data("{\\rtf1\\ansi B25 \(tag)}".utf8)],
            [.init("com.parla.b25.synthetic"): Data(newer ? [91, 92, 93] : [7, 8, 9]),
             .init("com.parla.b25.empty"): Data()]
        ]
    }
    init(_ controls: B25Controls) {
        self.controls = controls; wire = B25Wire(controls)
        board = NSPasteboard(name: .init(controls.board))
        // Exact production adapter, real monotonic clock, cancellable timers/mailbox.
        delivery = ClipboardDelivery(board: board)
    }
    func require(_ condition: Bool, _ code: B25Failure) throws {
        guard condition else { throw code }
    }
    func command(_ op: B25Op, caseNumber: Int, notBeforeMs: Double = 0) async throws -> B25NativeReply {
        let response = try await wire.exchange(op, caseNumber: caseNumber, notBeforeMs: notBeforeMs)
        ipc.append(response) // structural negative retained BEFORE positivity check
        guard case .native(let reply) = response else { throw B25Failure.protocolMismatch }
        try require(reply.ok && reply.equality, op == .readPrepared ? .payloadMismatch : .restorationMismatch)
        let counts = B25Schema.counts[reply.sequence-1]
        try require(reply.reads == counts.0 && reply.itemCount == counts.1 && reply.representationCount == counts.2, .protocolMismatch)
        return reply
    }
    func commit(_ baseline: B25Baseline) async throws {
        let response = try await wire.exchange(.commitOriginalBaseline, caseNumber: baseline.c, baseline: baseline)
        ipc.append(response) // metadata negatives retained, no invented native fields
        guard case .ack(let ack) = response else { throw B25Failure.protocolMismatch }
        try require(ack.accepted, .protocolMismatch)
        try require(board.changeCount == baseline.pub, .restorationMismatch) // after asynchronous ack
    }
    func capture(_ publication: Int? = nil) throws -> Snapshot {
        let before = board.changeCount
        try require((0...2_147_483_647).contains(before) && (publication == nil || before == publication), .restorationMismatch)
        guard let items = board.pasteboardItems, items.count == 2 else { throw B25Failure.restorationMismatch }
        var raw: Snapshot = [], names = 0, bytes = 0
        for (i,item) in items.enumerated() {
            let types = item.types
            try require(types.count == (i == 0 ? 3 : 2) && Set(types).count == types.count, .restorationMismatch)
            var values: [NSPasteboard.PasteboardType:Data] = [:]
            for type in types {
                names += type.rawValue.utf8.count
                try require(names <= 106 && fixtureDataReads < 15, .restorationMismatch)
                fixtureDataReads += 1
                guard let data = item.data(forType: type), data.count <= 65_536-bytes else { throw B25Failure.restorationMismatch }
                bytes += data.count; values[type] = data
            }
            raw.append(values)
        }
        try require(names == 106 && board.changeCount == before, .restorationMismatch)
        return raw // value dictionaries only, no native item retained
    }
    func installOriginal(_ number: Int) throws {
        try require(!delivery.isRestorePending, .restorationMismatch)
        boardVerified = false
        let values = Self.seed()
        try require(values.flatMap(\.values).reduce(0, { $0 + $1.count }) <= 65_536, .controls)
        let items = try values.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { try require(item.setData(data, forType: type), .nativeRefusal) }
            return item
        }
        let clear = board.clearContents()
        try require(board.writeObjects(items), .nativeRefusal)
        let pub = board.changeCount
        let raw = try capture(pub)
        originals.append(raw) // retain full captured RAM even if strict intake refuses below
        let baseline = try B25Baseline.make(raw: raw, role: "original", c: number, clear: clear,
            pub: pub, before: pub, after: board.changeCount, run: controls.runID, board: controls.board, nonce: controls.nonce)
        try require(baselines[number] == nil, .protocolMismatch)
        baselines[number] = baseline // immutable pre-mutation N, never reseeded/reassigned
    }
    func settle() async throws {
        let deadline = b25Milliseconds() + 9_500
        while delivery.isRestorePending {
            try require(!delivery.restoreFailed, .restorationMismatch)
            try require(b25Milliseconds() < deadline && b25Milliseconds() - started < 80_000, .settlementTimeout)
            // Suspension services main queue provider notices and production timers.
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    func evidence(_ store: DiagnosticStore) throws -> (DiagnosticRecord, DiagnosticClipboard) {
        guard let record = store.snapshot().records.first, let clip = record.clipboard else {
            throw B25Failure.receiptMismatch
        }
        return (record, clip)
    }
    func runCase(_ number: Int) async throws {
        activeCase = number; boardVerified = false; fixtureDataReads = 0
        activeCallBeforeMs = nil; activeCallAfterMs = nil; activeAccepted = nil
        activeInitialCount = nil; activePostMarkers = 0
        // Case 8 deliberately leaves case 7's eager restoration untouched. A new
        // delivery avoids confusing stopping-refusal with the actual UTF8 cap.
        if number < 8 {
            try installOriginal(number)
            guard let baseline = baselines[number] else { throw B25Failure.protocolMismatch }
            try await commit(baseline)
        }
        else { delivery = ClipboardDelivery(board: board) }
        let store = DiagnosticStore(countLimit: 1, appVersion: { nil })
        activeStore = store
        let diagnostic = store.start(id: UUID(), origin: .unknown)
        var posts = 0
        let countBefore = board.changeCount, before = b25Milliseconds()
        let text = number == 8 ? String(repeating: "x", count: 1_048_577) : "B25 prepared \(number) α 😀\n"
        let mode: ClipboardRestoreMode = number == 1 ? .fixed : .observableRequests
        if number < 8 {
            // Last native observation before the synchronous production call; no suspension intervenes.
            try require(board.changeCount == baselines[number]?.pub, .restorationMismatch)
        }
        let accepted = DiagnosticDispatch.paste(diagnostics: diagnostic) {
            delivery.paste(text, mode: mode, diagnostics: diagnostic) { posts += 1 }
        }
        let preparedPublicationCount = board.changeCount // before any independent replacement
        let after = b25Milliseconds()
        var replacement: Snapshot?, replacementPublication: Int?
        activeCallBeforeMs = before; activeCallAfterMs = after
        activeInitialCount = countBefore; activeAccepted = accepted; activePostMarkers = posts
        var reads: [B25NativeReply] = []
        var snapshotEqual = false, unchanged = false
        if number == 8 {
            try require(!accepted && posts == 0 && !delivery.isRestorePending, .oversizedMismatch)
            unchanged = board.changeCount == countBefore
            try require(unchanged, .oversizedMismatch)
            let raw = try capture(countBefore)
            try require(raw == originals[6], .oversizedMismatch)
            // No consumer fetch of case7's restored version before owner exit.
            snapshotEqual = true
        } else {
            try require(accepted && posts == 1 && delivery.isRestorePending, .nativeRefusal)
            if number == 7 {
                delivery.beginShutdown { self.shutdownReplies.append($0) }
                try require(shutdownReplies.isEmpty, .shutdownMismatch)
                let refusedCount = board.changeCount
                var secondPosts = 0
                let second = delivery.paste("B25 rejected second", mode: .observableRequests) { secondPosts += 1 }
                try require(!second && secondPosts == 0 && board.changeCount == refusedCount, .shutdownMismatch)
            }
            let offsets: [Double]
            switch number {
            case 1: offsets = [100]
            case 2: offsets = [100, 250, 400]
            case 3, 7: offsets = [2_000]
            case 4: offsets = [7_600]
            default: offsets = []
            }
            for offset in offsets {
                let reply = try await command(.readPrepared, caseNumber: number, notBeforeMs: after + offset)
                reads.append(reply)
                // A late/expired read is unqualified, never retried or repaired.
                if number == 4 { try require(reply.startMs - after < 7_900, .timingWindow) }
                if number == 3 || number == 7 {
                    try require((1_900...2_700).contains(reply.startMs - after), .timingWindow)
                }
                if number == 1 || number == 2 { try require(reply.endMs - before < 750, .timingWindow) }
            }
            if number == 6 {
                // Explicit acknowledgment orders the independent writer before settlement.
                let reply = try await command(.replace, caseNumber: number)
                reads.append(reply)
                guard let sealed = reply.baseline else { throw B25Failure.protocolMismatch }
                try require(sealed.pub != preparedPublicationCount && board.changeCount == sealed.pub, .restorationMismatch)
                let raw = try capture(sealed.pub) // independently read ALL replacement values
                try require(retainedReplacement == nil, .protocolMismatch)
                retainedReplacement = raw
                let own = try B25Baseline.make(raw: raw, role: "replacement", c: 6, clear: sealed.clear,
                    pub: sealed.pub, before: sealed.pub, after: board.changeCount,
                    run: controls.runID, board: controls.board, nonce: controls.nonce)
                try require(own == sealed, .restorationMismatch)
                replacement = raw; replacementPublication = sealed.pub
            }
            // Case 5 reads neither types/data nor prepared text before this completes.
            try await settle()
            let (_, clip) = try evidence(store)
            if number == 6 {
                try require(clip.restore == .skippedOwnershipChanged && clip.end == .ownershipChanged, .restorationMismatch)
            } else { try require(clip.restore == .restored, .restorationMismatch) }
            if number != 7 {
                let verification = try await command(number == 6 ? .verifyReplacement : .verifyOriginal, caseNumber: number)
                reads.append(verification); snapshotEqual = verification.equality
                if number == 6 { try require(verification.changeCount == replacementPublication && board.changeCount == replacementPublication, .restorationMismatch) }
            }
            // Owner snapshot reads happen only after the actual lease has settled.
            let raw = try capture(number == 6 ? replacementPublication : nil)
            let ownerEqual = number == 6 ? raw == replacement : raw == originals[number-1]
            if number == 6 { try require(board.changeCount == replacementPublication, .restorationMismatch) }
            try require(ownerEqual, .restorationMismatch)
            if number == 7 { snapshotEqual = ownerEqual }
            if number == 1 {
                try require(clip.end == .baselineTimer && clip.requests == 0 && !store.snapshot().records[0].receiptObserved,
                            .receiptMismatch)
            }
            if [2, 3, 4, 7].contains(number) {
                try require(clip.requests > 0 && clip.receipt == .observed && store.snapshot().records[0].receiptObserved && clip.supplyFailures == 0, .receiptMismatch)
                try require(clip.requestedDelayMs <= 8_000 && clip.requestedDelayMs >= 800, .receiptMismatch)
                try require(clip.end == .quietAfterObservableRequest || clip.end == .maximum, .receiptMismatch)
                if number == 3 || number == 7 {
                    try require((1_900...2_700).contains(clip.firstRequestMs ?? -1), .timingWindow)
                }
                if number == 4 {
                    try require((7_400..<8_000).contains(clip.firstRequestMs ?? -1), .timingWindow)
                }
            }
            if number == 5 {
                try require(clip.requests == 0 && !store.snapshot().records[0].receiptObserved &&
                    clip.receipt == .noObservableReceipt && clip.end == .maximum, .receiptMismatch)
            }
            if number == 7 { try require(shutdownReplies == [true], .shutdownMismatch) }
        }
        let fixtureExpected = number == 8 ? 5 : number == 6 ? 15 : 10
        try require(fixtureDataReads == fixtureExpected, .restorationMismatch)
        // Unchanged production snapshot has five source-derived calls (zero for oversized refusal).
        // This does not instrument native internal conversions or pretend to measure product calls.
        try require(fixtureDataReads + (number == 8 ? 0 : 5) == (number == 8 ? 5 : number == 6 ? 20 : 15), .restorationMismatch)
        boardVerified = snapshotEqual
        let (record, clip) = try evidence(store)
        try require(record.delivery == (number == 8 ? .refused : .postedUnverified), .receiptMismatch)
        if number == 8 { try require(clip.end == .preparationRefused && clip.restore == .untouched, .oversizedMismatch) }
        let preparedReads = reads.filter { $0.op == .readPrepared }
        observations.append(B25CaseObservation(number: number, postMarkers: posts,
            preparedReadCommands: preparedReads.count, consumerDataReads: reads.last?.reads ?? 0,
            firstReadOffsetMs: preparedReads.first.map { $0.startMs - after },
            lastReadOffsetMs: preparedReads.last.map { $0.endMs - after },
            eligibleFulfillments: clip.requests, ignoredFulfillments: clip.ignored,
            reportedFulfillmentCompletions: clip.requests + clip.ignored, supplyFailures: clip.supplyFailures,
            receiptObserved: record.receiptObserved, requestedDelayMs: clip.requestedDelayMs,
            elapsedMs: clip.elapsedMs, maximumOverrunMs: max(0, clip.elapsedMs - 8_000),
            end: clip.end, restore: clip.restore, receipt: clip.receipt, delivery: record.delivery,
            shutdownReplies: number == 7 ? shutdownReplies.count : 0,
            shutdownTrueReplies: number == 7 ? shutdownReplies.filter { $0 }.count : 0,
            snapshotEqual: snapshotEqual, changeCountUnchanged: unchanged))
    }
    func persist(_ failure: B25Failure?) throws {
        let unresolved = delivery.isRestorePending || delivery.restoreFailed || !boardVerified
        let receipt = B25OwnerReceipt(schema: 1,
            outcome: failure == nil ? "AWAITING_POST_OWNER_EXIT" : "NONPOSITIVE",
            failure: failure.map { B25FailureCode(code: $0.rawValue) }, completedCases: observations,
            ipc: ipc, activeEvidence: activeStore?.snapshot().records.first?.clipboard, activeCase: activeCase,
            shutdownReplies: shutdownReplies,
            activeCallBeforeMs: activeCallBeforeMs, activeCallAfterMs: activeCallAfterMs,
            activePostMarkers: activePostMarkers, activeAccepted: activeAccepted,
            activeInitialCount: activeInitialCount, currentCount: board.changeCount,
            pendingLease: delivery.isRestorePending, restoreFailed: delivery.restoreFailed,
            unresolvedOwnership: unresolved, ramSnapshotRetainedUntilExit: failure != nil,
            standaloneLifetimePass: false)
        let data = try JSONEncoder().encode(receipt)
        try data.write(to: controls.root.appendingPathComponent("owner.json"), options: .withoutOverwriting)
    }
}

final class NativePrivatePasteboardAcceptanceTests: XCTestCase {
    // The ONLY owner native test method. No board properties, setUp or tearDown.
    @MainActor func testOwnedPrivatePasteboardBaselineAcceptance() async throws {
        guard ProcessInfo.processInfo.environment["PARLA_RUN_OWNED_B25_BASELINE_NATIVE"] == "1" else {
            throw XCTSkip("B25 default-off; no native evidence")
        }
        let environment = ProcessInfo.processInfo.environment
        guard environment["B25_PRIVATE_NATIVE"] == nil && environment["PARLA_RUN_OWNED_B25_NATIVE"] == nil else {
            XCTFail("B25 old native gates refused"); return
        }
        // This gate and validation precede board construction AND any process work.
        let controls: B25Controls
        do { controls = try B25Controls.load(environment) }
        catch { XCTFail("B25 invalid explicit task controls"); return }
        let session = B25Session(controls)
        do {
            _ = try await session.command(.hello, caseNumber: 0)
            // Fresh identity is independently generated/attested by supervisor.
            // Refuse unexpected content without retrieving or clearing its data.
            try session.require(session.board.pasteboardItems?.isEmpty ?? true, .controls)
            for number in 1...8 { try await session.runCase(number) }
            _ = try await session.command(.armExit, caseNumber: 8)
            try session.persist(nil)
        } catch {
            // Never clear/release/retry here. Retain production lease + RAM seed.
            // A failed native restore can still own a promise; supervisor must
            // record unresolved ownership before any hard deadline termination.
            B25Session.failedOwners.append(session)
            try? session.persist((error as? B25Failure) ?? .transport)
            await session.wire.close()
            XCTFail("B25 NONPOSITIVE; stop after first refusal/failure/timeout")
            return
        }
        await session.wire.close()
        // Normal runner exit remains required. This cannot verify its own death.
        throw XCTSkip("B25 AWAITING_POST_OWNER_EXIT; external lifetime verdict required")
    }

    // Exact metadata-only selector. SYNTHETIC vectors; never unknown native-byte evidence.
    // No environment/control-path load, board construction, count/data/type read or child.
    func testOwnedPrivateBaselineMetadataControls() throws {
        let b0 = try JSONDecoder().decode(B25Baseline.self, from: XCTUnwrap(Data(base64Encoded: "eyJhZnRlciI6MTIzLCJiZWZvcmUiOjEyMywiYyI6MSwiY2xlYXIiOjEyMiwiZGlnZXN0IjoiYTUzYzk3NmNlNjRmY2RhODQ4MTRmZWI2OGMzNzFmZmMwMzFkMjhmODEyNTA4ZGI4OGViNDIzODI2YzY5YTY1MCIsIml0ZW1zIjpbW3siYiI6MjEsIm4iOjIyLCJzIjoiZDhkODkyNDJkYTVhMWRjZDJlNzM5OTc0OGE3YWNlMmE1OTdiZGUyYjk2OWY0YzI5M2NmNTNhMDNlMmI0NTE0OCIsInQiOiI0MDllMzczMzViZTk4YzRiODM1ZjE0ZGVjN2NlYzIxYTA1ODU3ZDBkOGMwZDExZmMzYmNjNzMwNGYyM2Q5OGQyIn0seyJiIjoyNSwibiI6MTAsInMiOiJjZTNhY2ZmYzUxYTYzMGQ3Mzc3MGRmOWQ2N2U1YTRiODNjODIxZTI4ODQ4N2QzMjM1MDQ1MzExYjc1ZDFlOWNiIiwidCI6ImNjMGIzMDliYTFkODllNjUwOGZlZmU5ZWM1YTQzYzI0Yjg5NjBmYzk5MjIzNDMwNWRkZGNkNGVhMGY1MTU3YjEifSx7ImIiOjI2LCJuIjozMiwicyI6IjkzMzhjMDEzYTM1MTExNDU3ZjA5MmQ4ZjNlZjhhODQzOGZkMDExNmRhNTdmNDVjZmNlMmY1ZWIxYjkyZDk5MmUiLCJ0IjoiZjBlNWJiODU4MjY3OTM5MTRjYjMxNTUxZjBkNmFhYjZlNWRmMzNhODE4YTI2OGM1NzQ3NDY1YjU1ZWU4MzdhOCJ9XSxbeyJiIjowLCJuIjoxOSwicyI6ImUzYjBjNDQyOThmYzFjMTQ5YWZiZjRjODk5NmZiOTI0MjdhZTQxZTQ2NDliOTM0Y2E0OTU5OTFiNzg1MmI4NTUiLCJ0IjoiODZjODIwMGVjMzgwNTQ3ZTZhOTYwNTIwZmE0NzZiNWU4M2QwOGI1MjdjNjE4ZjY1MDM1MmI2NTZhOWJlNjk0ZiJ9LHsiYiI6MywibiI6MjMsInMiOiI2NmE2NzU3MTUxZjhlZTU1ZGIxMjc3MTZjN2UzZGNlMGJlODA3NGI2NGUyMGVkYTU0MmU1YzFlNDZjYTljNDFlIiwidCI6ImVmMGI2OTk2MDk4MjgyNWRmMTMzY2UwYWViZTIxZTA4MjgyYjk1MzQzMTI0MzQ2NGQyN2Q5MWFkNjRiNTE1YTgifV1dLCJwdWIiOjEyMywicm9sZSI6Im9yaWdpbmFsIiwidiI6MX0=")))
        try b0.validated(run: "12345678-1234-4234-8234-123456789abc", board: "com.parla.b25.private.12345678-1234-4234-8234-123456789abc.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", nonce: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", caseNumber: 1, expectedRole: "original")
        let preimage0 = b0.preimage(run: "12345678-1234-4234-8234-123456789abc", board: "com.parla.b25.private.12345678-1234-4234-8234-123456789abc.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", nonce: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertEqual(preimage0, try XCTUnwrap(Data(base64Encoded: "Mjg6UGFybGEvQjI1L25hdGl2ZS1iYXNlbGluZS92MQo4Om9yaWdpbmFsCjM2OjEyMzQ1Njc4LTEyMzQtNDIzNC04MjM0LTEyMzQ1Njc4OWFiYwoxMjM6Y29tLnBhcmxhLmIyNS5wcml2YXRlLjEyMzQ1Njc4LTEyMzQtNDIzNC04MjM0LTEyMzQ1Njc4OWFiYy5hYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhCjY0OmFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWEKMToxCjM6MTIyCjM6MTIzCjM6MTIzCjM6MTIzCjE6MgoxOjAKMTozCjY0OjQwOWUzNzMzNWJlOThjNGI4MzVmMTRkZWM3Y2VjMjFhMDU4NTdkMGQ4YzBkMTFmYzNiY2M3MzA0ZjIzZDk4ZDIKMjoyMgoyOjIxCjY0OmQ4ZDg5MjQyZGE1YTFkY2QyZTczOTk3NDhhN2FjZTJhNTk3YmRlMmI5NjlmNGMyOTNjZjUzYTAzZTJiNDUxNDgKNjQ6Y2MwYjMwOWJhMWQ4OWU2NTA4ZmVmZTllYzVhNDNjMjRiODk2MGZjOTkyMjM0MzA1ZGRkY2Q0ZWEwZjUxNTdiMQoyOjEwCjI6MjUKNjQ6Y2UzYWNmZmM1MWE2MzBkNzM3NzBkZjlkNjdlNWE0YjgzYzgyMWUyODg0ODdkMzIzNTA0NTMxMWI3NWQxZTljYgo2NDpmMGU1YmI4NTgyNjc5MzkxNGNiMzE1NTFmMGQ2YWFiNmU1ZGYzM2E4MThhMjY4YzU3NDc0NjViNTVlZTgzN2E4CjI6MzIKMjoyNgo2NDo5MzM4YzAxM2EzNTExMTQ1N2YwOTJkOGYzZWY4YTg0MzhmZDAxMTZkYTU3ZjQ1Y2ZjZTJmNWViMWI5MmQ5OTJlCjE6MQoxOjIKNjQ6ODZjODIwMGVjMzgwNTQ3ZTZhOTYwNTIwZmE0NzZiNWU4M2QwOGI1MjdjNjE4ZjY1MDM1MmI2NTZhOWJlNjk0ZgoyOjE5CjE6MAo2NDplM2IwYzQ0Mjk4ZmMxYzE0OWFmYmY0Yzg5OTZmYjkyNDI3YWU0MWU0NjQ5YjkzNGNhNDk1OTkxYjc4NTJiODU1CjY0OmVmMGI2OTk2MDk4MjgyNWRmMTMzY2UwYWViZTIxZTA4MjgyYjk1MzQzMTI0MzQ2NGQyN2Q5MWFkNjRiNTE1YTgKMjoyMwoxOjMKNjQ6NjZhNjc1NzE1MWY4ZWU1NWRiMTI3NzE2YzdlM2RjZTBiZTgwNzRiNjRlMjBlZGE1NDJlNWMxZTQ2Y2E5YzQxZQo=")))
        XCTAssertEqual(b25Hash(preimage0), "a53c976ce64fcda84814feb68c371ffc031d28f812508db88eb423826c69a650")
        let b1 = try JSONDecoder().decode(B25Baseline.self, from: XCTUnwrap(Data(base64Encoded: "eyJhZnRlciI6MjE0NzQ4MzY0NywiYmVmb3JlIjoyMTQ3NDgzNjQ3LCJjIjo3LCJjbGVhciI6MjE0NzQ4MzY0NiwiZGlnZXN0IjoiOThjYWUxMmUzOTcxMTRjMDgyYzcxNGMwYzk2OGQwODEyYzI1NzQwOTViOTk3ZDljZWZiODIyZTFkNGU0YjE0ZSIsIml0ZW1zIjpbW3siYiI6MjEsIm4iOjIyLCJzIjoiZDhkODkyNDJkYTVhMWRjZDJlNzM5OTc0OGE3YWNlMmE1OTdiZGUyYjk2OWY0YzI5M2NmNTNhMDNlMmI0NTE0OCIsInQiOiI0MDllMzczMzViZTk4YzRiODM1ZjE0ZGVjN2NlYzIxYTA1ODU3ZDBkOGMwZDExZmMzYmNjNzMwNGYyM2Q5OGQyIn0seyJiIjoyNSwibiI6MTAsInMiOiJjZTNhY2ZmYzUxYTYzMGQ3Mzc3MGRmOWQ2N2U1YTRiODNjODIxZTI4ODQ4N2QzMjM1MDQ1MzExYjc1ZDFlOWNiIiwidCI6ImNjMGIzMDliYTFkODllNjUwOGZlZmU5ZWM1YTQzYzI0Yjg5NjBmYzk5MjIzNDMwNWRkZGNkNGVhMGY1MTU3YjEifSx7ImIiOjI2LCJuIjozMiwicyI6IjkzMzhjMDEzYTM1MTExNDU3ZjA5MmQ4ZjNlZjhhODQzOGZkMDExNmRhNTdmNDVjZmNlMmY1ZWIxYjkyZDk5MmUiLCJ0IjoiZjBlNWJiODU4MjY3OTM5MTRjYjMxNTUxZjBkNmFhYjZlNWRmMzNhODE4YTI2OGM1NzQ3NDY1YjU1ZWU4MzdhOCJ9XSxbeyJiIjowLCJuIjoxOSwicyI6ImUzYjBjNDQyOThmYzFjMTQ5YWZiZjRjODk5NmZiOTI0MjdhZTQxZTQ2NDliOTM0Y2E0OTU5OTFiNzg1MmI4NTUiLCJ0IjoiODZjODIwMGVjMzgwNTQ3ZTZhOTYwNTIwZmE0NzZiNWU4M2QwOGI1MjdjNjE4ZjY1MDM1MmI2NTZhOWJlNjk0ZiJ9LHsiYiI6MywibiI6MjMsInMiOiI2NmE2NzU3MTUxZjhlZTU1ZGIxMjc3MTZjN2UzZGNlMGJlODA3NGI2NGUyMGVkYTU0MmU1YzFlNDZjYTljNDFlIiwidCI6ImVmMGI2OTk2MDk4MjgyNWRmMTMzY2UwYWViZTIxZTA4MjgyYjk1MzQzMTI0MzQ2NGQyN2Q5MWFkNjRiNTE1YTgifV1dLCJwdWIiOjIxNDc0ODM2NDcsInJvbGUiOiJvcmlnaW5hbCIsInYiOjF9")))
        try b1.validated(run: "12345678-1234-4234-8234-123456789abc", board: "com.parla.b25.private.12345678-1234-4234-8234-123456789abc.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", nonce: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", caseNumber: 7, expectedRole: "original")
        let preimage1 = b1.preimage(run: "12345678-1234-4234-8234-123456789abc", board: "com.parla.b25.private.12345678-1234-4234-8234-123456789abc.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", nonce: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertEqual(preimage1, try XCTUnwrap(Data(base64Encoded: "Mjg6UGFybGEvQjI1L25hdGl2ZS1iYXNlbGluZS92MQo4Om9yaWdpbmFsCjM2OjEyMzQ1Njc4LTEyMzQtNDIzNC04MjM0LTEyMzQ1Njc4OWFiYwoxMjM6Y29tLnBhcmxhLmIyNS5wcml2YXRlLjEyMzQ1Njc4LTEyMzQtNDIzNC04MjM0LTEyMzQ1Njc4OWFiYy5hYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhCjY0OmFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWEKMTo3CjEwOjIxNDc0ODM2NDYKMTA6MjE0NzQ4MzY0NwoxMDoyMTQ3NDgzNjQ3CjEwOjIxNDc0ODM2NDcKMToyCjE6MAoxOjMKNjQ6NDA5ZTM3MzM1YmU5OGM0YjgzNWYxNGRlYzdjZWMyMWEwNTg1N2QwZDhjMGQxMWZjM2JjYzczMDRmMjNkOThkMgoyOjIyCjI6MjEKNjQ6ZDhkODkyNDJkYTVhMWRjZDJlNzM5OTc0OGE3YWNlMmE1OTdiZGUyYjk2OWY0YzI5M2NmNTNhMDNlMmI0NTE0OAo2NDpjYzBiMzA5YmExZDg5ZTY1MDhmZWZlOWVjNWE0M2MyNGI4OTYwZmM5OTIyMzQzMDVkZGRjZDRlYTBmNTE1N2IxCjI6MTAKMjoyNQo2NDpjZTNhY2ZmYzUxYTYzMGQ3Mzc3MGRmOWQ2N2U1YTRiODNjODIxZTI4ODQ4N2QzMjM1MDQ1MzExYjc1ZDFlOWNiCjY0OmYwZTViYjg1ODI2NzkzOTE0Y2IzMTU1MWYwZDZhYWI2ZTVkZjMzYTgxOGEyNjhjNTc0NzQ2NWI1NWVlODM3YTgKMjozMgoyOjI2CjY0OjkzMzhjMDEzYTM1MTExNDU3ZjA5MmQ4ZjNlZjhhODQzOGZkMDExNmRhNTdmNDVjZmNlMmY1ZWIxYjkyZDk5MmUKMToxCjE6Mgo2NDo4NmM4MjAwZWMzODA1NDdlNmE5NjA1MjBmYTQ3NmI1ZTgzZDA4YjUyN2M2MThmNjUwMzUyYjY1NmE5YmU2OTRmCjI6MTkKMTowCjY0OmUzYjBjNDQyOThmYzFjMTQ5YWZiZjRjODk5NmZiOTI0MjdhZTQxZTQ2NDliOTM0Y2E0OTU5OTFiNzg1MmI4NTUKNjQ6ZWYwYjY5OTYwOTgyODI1ZGYxMzNjZTBhZWJlMjFlMDgyODJiOTUzNDMxMjQzNDY0ZDI3ZDkxYWQ2NGI1MTVhOAoyOjIzCjE6Mwo2NDo2NmE2NzU3MTUxZjhlZTU1ZGIxMjc3MTZjN2UzZGNlMGJlODA3NGI2NGUyMGVkYTU0MmU1YzFlNDZjYTljNDFlCg==")))
        XCTAssertEqual(b25Hash(preimage1), "98cae12e397114c082c714c0c968d0812c2574095b997d9cefb822e1d4e4b14e")
        let b2 = try JSONDecoder().decode(B25Baseline.self, from: XCTUnwrap(Data(base64Encoded: "eyJhZnRlciI6MjE0NzQ4MzY0NywiYmVmb3JlIjoyMTQ3NDgzNjQ3LCJjIjo2LCJjbGVhciI6MjE0NzQ4MzY0NiwiZGlnZXN0IjoiZjVkODVlMjhkYzEyN2Y0MjUyNWVjODc3ODI5NTE5OGJmYzc1OGRiMzVjMjA3NDNlYTgxNzExNWZlNjllMDhjOCIsIml0ZW1zIjpbW3siYiI6MjQsIm4iOjIyLCJzIjoiN2UzNzZlZjUxZWVkNzNkNGY0OWQ0NDY0Mjk5NjAwNzVlNjQ4MDMxMjM5YzdjMzQ2ZTNiNGZjN2I3Nzg5YWE2MyIsInQiOiI0MDllMzczMzViZTk4YzRiODM1ZjE0ZGVjN2NlYzIxYTA1ODU3ZDBkOGMwZDExZmMzYmNjNzMwNGYyM2Q5OGQyIn0seyJiIjoyOCwibiI6MTAsInMiOiI1MjFjNjA0YmI1OTk4MWQxOTYyNTU2ZDk5YWI2M2ExODVjZGQyNzNmODJiNzc4YzIzYzI4NDkzZTUyY2JjZjY3IiwidCI6ImNjMGIzMDliYTFkODllNjUwOGZlZmU5ZWM1YTQzYzI0Yjg5NjBmYzk5MjIzNDMwNWRkZGNkNGVhMGY1MTU3YjEifSx7ImIiOjY1NDgxLCJuIjozMiwicyI6IjkzMzhjMDEzYTM1MTExNDU3ZjA5MmQ4ZjNlZjhhODQzOGZkMDExNmRhNTdmNDVjZmNlMmY1ZWIxYjkyZDk5MmUiLCJ0IjoiZjBlNWJiODU4MjY3OTM5MTRjYjMxNTUxZjBkNmFhYjZlNWRmMzNhODE4YTI2OGM1NzQ3NDY1YjU1ZWU4MzdhOCJ9XSxbeyJiIjowLCJuIjoxOSwicyI6ImUzYjBjNDQyOThmYzFjMTQ5YWZiZjRjODk5NmZiOTI0MjdhZTQxZTQ2NDliOTM0Y2E0OTU5OTFiNzg1MmI4NTUiLCJ0IjoiODZjODIwMGVjMzgwNTQ3ZTZhOTYwNTIwZmE0NzZiNWU4M2QwOGI1MjdjNjE4ZjY1MDM1MmI2NTZhOWJlNjk0ZiJ9LHsiYiI6MywibiI6MjMsInMiOiI4ZTg5OGJlNmQyYzkyNjc1ZjZkNjQ2MjU5NTcxYmM5OTBmZDMwZmNjZGRiNzM5MTNhOThkNWYwNjA3NDIwNWQ2IiwidCI6ImVmMGI2OTk2MDk4MjgyNWRmMTMzY2UwYWViZTIxZTA4MjgyYjk1MzQzMTI0MzQ2NGQyN2Q5MWFkNjRiNTE1YTgifV1dLCJwdWIiOjIxNDc0ODM2NDcsInJvbGUiOiJyZXBsYWNlbWVudCIsInYiOjF9")))
        try b2.validated(run: "12345678-1234-4234-8234-123456789abc", board: "com.parla.b25.private.12345678-1234-4234-8234-123456789abc.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", nonce: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", caseNumber: 6, expectedRole: "replacement")
        let preimage2 = b2.preimage(run: "12345678-1234-4234-8234-123456789abc", board: "com.parla.b25.private.12345678-1234-4234-8234-123456789abc.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", nonce: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertEqual(preimage2, try XCTUnwrap(Data(base64Encoded: "Mjg6UGFybGEvQjI1L25hdGl2ZS1iYXNlbGluZS92MQoxMTpyZXBsYWNlbWVudAozNjoxMjM0NTY3OC0xMjM0LTQyMzQtODIzNC0xMjM0NTY3ODlhYmMKMTIzOmNvbS5wYXJsYS5iMjUucHJpdmF0ZS4xMjM0NTY3OC0xMjM0LTQyMzQtODIzNC0xMjM0NTY3ODlhYmMuYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYQo2NDphYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhCjE6NgoxMDoyMTQ3NDgzNjQ2CjEwOjIxNDc0ODM2NDcKMTA6MjE0NzQ4MzY0NwoxMDoyMTQ3NDgzNjQ3CjE6MgoxOjAKMTozCjY0OjQwOWUzNzMzNWJlOThjNGI4MzVmMTRkZWM3Y2VjMjFhMDU4NTdkMGQ4YzBkMTFmYzNiY2M3MzA0ZjIzZDk4ZDIKMjoyMgoyOjI0CjY0OjdlMzc2ZWY1MWVlZDczZDRmNDlkNDQ2NDI5OTYwMDc1ZTY0ODAzMTIzOWM3YzM0NmUzYjRmYzdiNzc4OWFhNjMKNjQ6Y2MwYjMwOWJhMWQ4OWU2NTA4ZmVmZTllYzVhNDNjMjRiODk2MGZjOTkyMjM0MzA1ZGRkY2Q0ZWEwZjUxNTdiMQoyOjEwCjI6MjgKNjQ6NTIxYzYwNGJiNTk5ODFkMTk2MjU1NmQ5OWFiNjNhMTg1Y2RkMjczZjgyYjc3OGMyM2MyODQ5M2U1MmNiY2Y2Nwo2NDpmMGU1YmI4NTgyNjc5MzkxNGNiMzE1NTFmMGQ2YWFiNmU1ZGYzM2E4MThhMjY4YzU3NDc0NjViNTVlZTgzN2E4CjI6MzIKNTo2NTQ4MQo2NDo5MzM4YzAxM2EzNTExMTQ1N2YwOTJkOGYzZWY4YTg0MzhmZDAxMTZkYTU3ZjQ1Y2ZjZTJmNWViMWI5MmQ5OTJlCjE6MQoxOjIKNjQ6ODZjODIwMGVjMzgwNTQ3ZTZhOTYwNTIwZmE0NzZiNWU4M2QwOGI1MjdjNjE4ZjY1MDM1MmI2NTZhOWJlNjk0ZgoyOjE5CjE6MAo2NDplM2IwYzQ0Mjk4ZmMxYzE0OWFmYmY0Yzg5OTZmYjkyNDI3YWU0MWU0NjQ5YjkzNGNhNDk1OTkxYjc4NTJiODU1CjY0OmVmMGI2OTk2MDk4MjgyNWRmMTMzY2UwYWViZTIxZTA4MjgyYjk1MzQzMTI0MzQ2NGQyN2Q5MWFkNjRiNTE1YTgKMjoyMwoxOjMKNjQ6OGU4OThiZTZkMmM5MjY3NWY2ZDY0NjI1OTU3MWJjOTkwZmQzMGZjY2RkYjczOTEzYTk4ZDVmMDYwNzQyMDVkNgo=")))
        XCTAssertEqual(b25Hash(preimage2), "f5d85e28dc127f42525ec8778295198bfc758db35c20743ea817115fe69e08c8")
        let command2 = try XCTUnwrap(Data(base64Encoded: "eyJiYXNlbGluZSI6eyJhZnRlciI6MjE0NzQ4MzY0NywiYmVmb3JlIjoyMTQ3NDgzNjQ3LCJjIjoxLCJjbGVhciI6MjE0NzQ4MzY0NiwiZGlnZXN0IjoiZTBkOGM4NWE3ZGEyMzg2Yjk5MjU3ZmVkMjk1N2QyZTRjZGY5NmIwZTg2M2ZhYTc4MmY4NTA4NjU0N2Y0ODA5NiIsIml0ZW1zIjpbW3siYiI6MjEsIm4iOjIyLCJzIjoiZDhkODkyNDJkYTVhMWRjZDJlNzM5OTc0OGE3YWNlMmE1OTdiZGUyYjk2OWY0YzI5M2NmNTNhMDNlMmI0NTE0OCIsInQiOiI0MDllMzczMzViZTk4YzRiODM1ZjE0ZGVjN2NlYzIxYTA1ODU3ZDBkOGMwZDExZmMzYmNjNzMwNGYyM2Q5OGQyIn0seyJiIjoyNSwibiI6MTAsInMiOiJjZTNhY2ZmYzUxYTYzMGQ3Mzc3MGRmOWQ2N2U1YTRiODNjODIxZTI4ODQ4N2QzMjM1MDQ1MzExYjc1ZDFlOWNiIiwidCI6ImNjMGIzMDliYTFkODllNjUwOGZlZmU5ZWM1YTQzYzI0Yjg5NjBmYzk5MjIzNDMwNWRkZGNkNGVhMGY1MTU3YjEifSx7ImIiOjI2LCJuIjozMiwicyI6IjkzMzhjMDEzYTM1MTExNDU3ZjA5MmQ4ZjNlZjhhODQzOGZkMDExNmRhNTdmNDVjZmNlMmY1ZWIxYjkyZDk5MmUiLCJ0IjoiZjBlNWJiODU4MjY3OTM5MTRjYjMxNTUxZjBkNmFhYjZlNWRmMzNhODE4YTI2OGM1NzQ3NDY1YjU1ZWU4MzdhOCJ9XSxbeyJiIjowLCJuIjoxOSwicyI6ImUzYjBjNDQyOThmYzFjMTQ5YWZiZjRjODk5NmZiOTI0MjdhZTQxZTQ2NDliOTM0Y2E0OTU5OTFiNzg1MmI4NTUiLCJ0IjoiODZjODIwMGVjMzgwNTQ3ZTZhOTYwNTIwZmE0NzZiNWU4M2QwOGI1MjdjNjE4ZjY1MDM1MmI2NTZhOWJlNjk0ZiJ9LHsiYiI6MywibiI6MjMsInMiOiI2NmE2NzU3MTUxZjhlZTU1ZGIxMjc3MTZjN2UzZGNlMGJlODA3NGI2NGUyMGVkYTU0MmU1YzFlNDZjYTljNDFlIiwidCI6ImVmMGI2OTk2MDk4MjgyNWRmMTMzY2UwYWViZTIxZTA4MjgyYjk1MzQzMTI0MzQ2NGQyN2Q5MWFkNjRiNTE1YTgifV1dLCJwdWIiOjIxNDc0ODM2NDcsInJvbGUiOiJvcmlnaW5hbCIsInYiOjF9LCJib2FyZCI6ImNvbS5wYXJsYS5iMjUucHJpdmF0ZS4xMjM0NTY3OC0xMjM0LTQyMzQtODIzNC0xMjM0NTY3ODlhYmMuYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsImNhc2VOdW1iZXIiOjEsIm5vbmNlIjoiYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsIm5vdEJlZm9yZU1zIjowLCJvcCI6ImNvbW1pdE9yaWdpbmFsQmFzZWxpbmUiLCJvd25lckV4aXRlZCI6ZmFsc2UsInJ1bklEIjoiMTIzNDU2NzgtMTIzNC00MjM0LTgyMzQtMTIzNDU2Nzg5YWJjIiwic2VxdWVuY2UiOjIsInZlcnNpb24iOjF9"))
        let reply2 = try XCTUnwrap(Data(base64Encoded: "eyJhY2NlcHRlZCI6dHJ1ZSwiYm9hcmQiOiJjb20ucGFybGEuYjI1LnByaXZhdGUuMTIzNDU2NzgtMTIzNC00MjM0LTgyMzQtMTIzNDU2Nzg5YWJjLmFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWEiLCJjYXNlTnVtYmVyIjoxLCJkYXRhUmVhZHMiOjAsImRpZ2VzdCI6ImUwZDhjODVhN2RhMjM4NmI5OTI1N2ZlZDI5NTdkMmU0Y2RmOTZiMGU4NjNmYWE3ODJmODUwODY1NDdmNDgwOTYiLCJlbmRNcyI6MTAwMDAwMDAwMDAwMC4wLCJraW5kIjoibWV0YWRhdGFBY2siLCJub25jZSI6ImFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWEiLCJvcCI6ImNvbW1pdE9yaWdpbmFsQmFzZWxpbmUiLCJyb2xlIjoib3JpZ2luYWwiLCJydW5JRCI6IjEyMzQ1Njc4LTEyMzQtNDIzNC04MjM0LTEyMzQ1Njc4OWFiYyIsInNlcXVlbmNlIjoyLCJzdGFydE1zIjoxMDAwMDAwMDAwMDAwLjAsInZlcnNpb24iOjF9"))
        let decoded2 = try B25Schema.command(command2)
        _ = try B25Schema.response(reply2, command: decoded2, now: 1e12, began: 1e12)
        let command19 = try XCTUnwrap(Data(base64Encoded: "eyJib2FyZCI6ImNvbS5wYXJsYS5iMjUucHJpdmF0ZS4xMjM0NTY3OC0xMjM0LTQyMzQtODIzNC0xMjM0NTY3ODlhYmMuYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsImNhc2VOdW1iZXIiOjYsIm5vbmNlIjoiYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsIm5vdEJlZm9yZU1zIjowLCJvcCI6InJlcGxhY2UiLCJvd25lckV4aXRlZCI6ZmFsc2UsInJ1bklEIjoiMTIzNDU2NzgtMTIzNC00MjM0LTgyMzQtMTIzNDU2Nzg5YWJjIiwic2VxdWVuY2UiOjE5LCJ2ZXJzaW9uIjoxfQ=="))
        let reply19 = try XCTUnwrap(Data(base64Encoded: "eyJiYXNlbGluZSI6eyJhZnRlciI6MjE0NzQ4MzY0NywiYmVmb3JlIjoyMTQ3NDgzNjQ3LCJjIjo2LCJjbGVhciI6MjE0NzQ4MzY0NiwiZGlnZXN0IjoiZjVkODVlMjhkYzEyN2Y0MjUyNWVjODc3ODI5NTE5OGJmYzc1OGRiMzVjMjA3NDNlYTgxNzExNWZlNjllMDhjOCIsIml0ZW1zIjpbW3siYiI6MjQsIm4iOjIyLCJzIjoiN2UzNzZlZjUxZWVkNzNkNGY0OWQ0NDY0Mjk5NjAwNzVlNjQ4MDMxMjM5YzdjMzQ2ZTNiNGZjN2I3Nzg5YWE2MyIsInQiOiI0MDllMzczMzViZTk4YzRiODM1ZjE0ZGVjN2NlYzIxYTA1ODU3ZDBkOGMwZDExZmMzYmNjNzMwNGYyM2Q5OGQyIn0seyJiIjoyOCwibiI6MTAsInMiOiI1MjFjNjA0YmI1OTk4MWQxOTYyNTU2ZDk5YWI2M2ExODVjZGQyNzNmODJiNzc4YzIzYzI4NDkzZTUyY2JjZjY3IiwidCI6ImNjMGIzMDliYTFkODllNjUwOGZlZmU5ZWM1YTQzYzI0Yjg5NjBmYzk5MjIzNDMwNWRkZGNkNGVhMGY1MTU3YjEifSx7ImIiOjY1NDgxLCJuIjozMiwicyI6IjkzMzhjMDEzYTM1MTExNDU3ZjA5MmQ4ZjNlZjhhODQzOGZkMDExNmRhNTdmNDVjZmNlMmY1ZWIxYjkyZDk5MmUiLCJ0IjoiZjBlNWJiODU4MjY3OTM5MTRjYjMxNTUxZjBkNmFhYjZlNWRmMzNhODE4YTI2OGM1NzQ3NDY1YjU1ZWU4MzdhOCJ9XSxbeyJiIjowLCJuIjoxOSwicyI6ImUzYjBjNDQyOThmYzFjMTQ5YWZiZjRjODk5NmZiOTI0MjdhZTQxZTQ2NDliOTM0Y2E0OTU5OTFiNzg1MmI4NTUiLCJ0IjoiODZjODIwMGVjMzgwNTQ3ZTZhOTYwNTIwZmE0NzZiNWU4M2QwOGI1MjdjNjE4ZjY1MDM1MmI2NTZhOWJlNjk0ZiJ9LHsiYiI6MywibiI6MjMsInMiOiI4ZTg5OGJlNmQyYzkyNjc1ZjZkNjQ2MjU5NTcxYmM5OTBmZDMwZmNjZGRiNzM5MTNhOThkNWYwNjA3NDIwNWQ2IiwidCI6ImVmMGI2OTk2MDk4MjgyNWRmMTMzY2UwYWViZTIxZTA4MjgyYjk1MzQzMTI0MzQ2NGQyN2Q5MWFkNjRiNTE1YTgifV1dLCJwdWIiOjIxNDc0ODM2NDcsInJvbGUiOiJyZXBsYWNlbWVudCIsInYiOjF9LCJib2FyZCI6ImNvbS5wYXJsYS5iMjUucHJpdmF0ZS4xMjM0NTY3OC0xMjM0LTQyMzQtODIzNC0xMjM0NTY3ODlhYmMuYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsImNhc2VOdW1iZXIiOjYsImNoYW5nZUNvdW50IjoyMTQ3NDgzNjQ3LCJlbmRNcyI6MTAwMDAwMDAwMDAwMC4wLCJlcXVhbGl0eSI6dHJ1ZSwiaXRlbUNvdW50IjoyLCJraW5kIjoibmF0aXZlIiwibm9uY2UiOiJhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhIiwib2siOnRydWUsIm9wIjoicmVwbGFjZSIsInJlYWRzIjo1LCJyZXByZXNlbnRhdGlvbkNvdW50Ijo1LCJydW5JRCI6IjEyMzQ1Njc4LTEyMzQtNDIzNC04MjM0LTEyMzQ1Njc4OWFiYyIsInNlcXVlbmNlIjoxOSwic3RhcnRNcyI6MTAwMDAwMDAwMDAwMC4wLCJ2ZXJzaW9uIjoxfQ=="))
        let decoded19 = try B25Schema.command(command19)
        _ = try B25Schema.response(reply19, command: decoded19, now: 1e12, began: 1e12)
        let command21 = try XCTUnwrap(Data(base64Encoded: "eyJiYXNlbGluZSI6eyJhZnRlciI6MjE0NzQ4MzY0NywiYmVmb3JlIjoyMTQ3NDgzNjQ3LCJjIjo3LCJjbGVhciI6MjE0NzQ4MzY0NiwiZGlnZXN0IjoiOThjYWUxMmUzOTcxMTRjMDgyYzcxNGMwYzk2OGQwODEyYzI1NzQwOTViOTk3ZDljZWZiODIyZTFkNGU0YjE0ZSIsIml0ZW1zIjpbW3siYiI6MjEsIm4iOjIyLCJzIjoiZDhkODkyNDJkYTVhMWRjZDJlNzM5OTc0OGE3YWNlMmE1OTdiZGUyYjk2OWY0YzI5M2NmNTNhMDNlMmI0NTE0OCIsInQiOiI0MDllMzczMzViZTk4YzRiODM1ZjE0ZGVjN2NlYzIxYTA1ODU3ZDBkOGMwZDExZmMzYmNjNzMwNGYyM2Q5OGQyIn0seyJiIjoyNSwibiI6MTAsInMiOiJjZTNhY2ZmYzUxYTYzMGQ3Mzc3MGRmOWQ2N2U1YTRiODNjODIxZTI4ODQ4N2QzMjM1MDQ1MzExYjc1ZDFlOWNiIiwidCI6ImNjMGIzMDliYTFkODllNjUwOGZlZmU5ZWM1YTQzYzI0Yjg5NjBmYzk5MjIzNDMwNWRkZGNkNGVhMGY1MTU3YjEifSx7ImIiOjI2LCJuIjozMiwicyI6IjkzMzhjMDEzYTM1MTExNDU3ZjA5MmQ4ZjNlZjhhODQzOGZkMDExNmRhNTdmNDVjZmNlMmY1ZWIxYjkyZDk5MmUiLCJ0IjoiZjBlNWJiODU4MjY3OTM5MTRjYjMxNTUxZjBkNmFhYjZlNWRmMzNhODE4YTI2OGM1NzQ3NDY1YjU1ZWU4MzdhOCJ9XSxbeyJiIjowLCJuIjoxOSwicyI6ImUzYjBjNDQyOThmYzFjMTQ5YWZiZjRjODk5NmZiOTI0MjdhZTQxZTQ2NDliOTM0Y2E0OTU5OTFiNzg1MmI4NTUiLCJ0IjoiODZjODIwMGVjMzgwNTQ3ZTZhOTYwNTIwZmE0NzZiNWU4M2QwOGI1MjdjNjE4ZjY1MDM1MmI2NTZhOWJlNjk0ZiJ9LHsiYiI6MywibiI6MjMsInMiOiI2NmE2NzU3MTUxZjhlZTU1ZGIxMjc3MTZjN2UzZGNlMGJlODA3NGI2NGUyMGVkYTU0MmU1YzFlNDZjYTljNDFlIiwidCI6ImVmMGI2OTk2MDk4MjgyNWRmMTMzY2UwYWViZTIxZTA4MjgyYjk1MzQzMTI0MzQ2NGQyN2Q5MWFkNjRiNTE1YTgifV1dLCJwdWIiOjIxNDc0ODM2NDcsInJvbGUiOiJvcmlnaW5hbCIsInYiOjF9LCJib2FyZCI6ImNvbS5wYXJsYS5iMjUucHJpdmF0ZS4xMjM0NTY3OC0xMjM0LTQyMzQtODIzNC0xMjM0NTY3ODlhYmMuYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsImNhc2VOdW1iZXIiOjcsIm5vbmNlIjoiYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsIm5vdEJlZm9yZU1zIjowLCJvcCI6ImNvbW1pdE9yaWdpbmFsQmFzZWxpbmUiLCJvd25lckV4aXRlZCI6ZmFsc2UsInJ1bklEIjoiMTIzNDU2NzgtMTIzNC00MjM0LTgyMzQtMTIzNDU2Nzg5YWJjIiwic2VxdWVuY2UiOjIxLCJ2ZXJzaW9uIjoxfQ=="))
        let reply21 = try XCTUnwrap(Data(base64Encoded: "eyJhY2NlcHRlZCI6dHJ1ZSwiYm9hcmQiOiJjb20ucGFybGEuYjI1LnByaXZhdGUuMTIzNDU2NzgtMTIzNC00MjM0LTgyMzQtMTIzNDU2Nzg5YWJjLmFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWEiLCJjYXNlTnVtYmVyIjo3LCJkYXRhUmVhZHMiOjAsImRpZ2VzdCI6Ijk4Y2FlMTJlMzk3MTE0YzA4MmM3MTRjMGM5NjhkMDgxMmMyNTc0MDk1Yjk5N2Q5Y2VmYjgyMmUxZDRlNGIxNGUiLCJlbmRNcyI6MTAwMDAwMDAwMDAwMC4wLCJraW5kIjoibWV0YWRhdGFBY2siLCJub25jZSI6ImFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWEiLCJvcCI6ImNvbW1pdE9yaWdpbmFsQmFzZWxpbmUiLCJyb2xlIjoib3JpZ2luYWwiLCJydW5JRCI6IjEyMzQ1Njc4LTEyMzQtNDIzNC04MjM0LTEyMzQ1Njc4OWFiYyIsInNlcXVlbmNlIjoyMSwic3RhcnRNcyI6MTAwMDAwMDAwMDAwMC4wLCJ2ZXJzaW9uIjoxfQ=="))
        let decoded21 = try B25Schema.command(command21)
        _ = try B25Schema.response(reply21, command: decoded21, now: 1e12, began: 1e12)
        var boundary = command2
        boundary.append(Data(repeating: 32, count: 4095-boundary.count))
        _ = try B25Schema.command(boundary) // reader supplies the4096th LF byte
        boundary.append(32)
        XCTAssertThrowsError(try B25Schema.command(boundary)) //4097 including LF
        XCTAssertThrowsError(try B25Schema.command(XCTUnwrap(Data(base64Encoded: "eyJiYXNlbGluZSI6eyJhZnRlciI6MjE0NzQ4MzY0NywiYmVmb3JlIjoyMTQ3NDgzNjQ3LCJjIjoxLCJjbGVhciI6MjE0NzQ4MzY0NiwiZGlnZXN0IjoiZTBkOGM4NWE3ZGEyMzg2Yjk5MjU3ZmVkMjk1N2QyZTRjZGY5NmIwZTg2M2ZhYTc4MmY4NTA4NjU0N2Y0ODA5NiIsIml0ZW1zIjpbW3siYiI6MjEsIm4iOjIyLCJzIjoiZDhkODkyNDJkYTVhMWRjZDJlNzM5OTc0OGE3YWNlMmE1OTdiZGUyYjk2OWY0YzI5M2NmNTNhMDNlMmI0NTE0OCIsInQiOiI0MDllMzczMzViZTk4YzRiODM1ZjE0ZGVjN2NlYzIxYTA1ODU3ZDBkOGMwZDExZmMzYmNjNzMwNGYyM2Q5OGQyIn0seyJiIjoyNSwibiI6MTAsInMiOiJjZTNhY2ZmYzUxYTYzMGQ3Mzc3MGRmOWQ2N2U1YTRiODNjODIxZTI4ODQ4N2QzMjM1MDQ1MzExYjc1ZDFlOWNiIiwidCI6ImNjMGIzMDliYTFkODllNjUwOGZlZmU5ZWM1YTQzYzI0Yjg5NjBmYzk5MjIzNDMwNWRkZGNkNGVhMGY1MTU3YjEifSx7ImIiOjI2LCJuIjozMiwicyI6IjkzMzhjMDEzYTM1MTExNDU3ZjA5MmQ4ZjNlZjhhODQzOGZkMDExNmRhNTdmNDVjZmNlMmY1ZWIxYjkyZDk5MmUiLCJ0IjoiZjBlNWJiODU4MjY3OTM5MTRjYjMxNTUxZjBkNmFhYjZlNWRmMzNhODE4YTI2OGM1NzQ3NDY1YjU1ZWU4MzdhOCJ9XSxbeyJiIjowLCJuIjoxOSwicyI6ImUzYjBjNDQyOThmYzFjMTQ5YWZiZjRjODk5NmZiOTI0MjdhZTQxZTQ2NDliOTM0Y2E0OTU5OTFiNzg1MmI4NTUiLCJ0IjoiODZjODIwMGVjMzgwNTQ3ZTZhOTYwNTIwZmE0NzZiNWU4M2QwOGI1MjdjNjE4ZjY1MDM1MmI2NTZhOWJlNjk0ZiJ9LHsiYiI6MywibiI6MjMsInMiOiI2NmE2NzU3MTUxZjhlZTU1ZGIxMjc3MTZjN2UzZGNlMGJlODA3NGI2NGUyMGVkYTU0MmU1YzFlNDZjYTljNDFlIiwidCI6ImVmMGI2OTk2MDk4MjgyNWRmMTMzY2UwYWViZTIxZTA4MjgyYjk1MzQzMTI0MzQ2NGQyN2Q5MWFkNjRiNTE1YTgifV1dLCJwdWIiOjIxNDc0ODM2NDcsInJvbGUiOiJvcmlnaW5hbCIsInYiOjF9LCJib2FyZCI6ImNvbS5wYXJsYS5iMjUucHJpdmF0ZS4xMjM0NTY3OC0xMjM0LTQyMzQtODIzNC0xMjM0NTY3ODlhYmMuYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsImNhc2VOdW1iZXIiOjEsIm5vbmNlIjoiYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsIm5vdEJlZm9yZU1zIjowLCJvcCI6ImNvbW1pdE9yaWdpbmFsQmFzZWxpbmUiLCJvd25lckV4aXRlZCI6ZmFsc2UsInJ1bklEIjoiMTIzNDU2NzgtMTIzNC00MjM0LTgyMzQtMTIzNDU2Nzg5YWJjIiwic2VxdWVuY2UiOnRydWUsInZlcnNpb24iOjF9"))))
        XCTAssertThrowsError(try B25Schema.command(XCTUnwrap(Data(base64Encoded: "eyJiYXNlbGluZSI6eyJhZnRlciI6MjE0NzQ4MzY0NywiYmVmb3JlIjoyMTQ3NDgzNjQ3LCJjIjoxLCJjbGVhciI6MjE0NzQ4MzY0NiwiZGlnZXN0IjoiZTBkOGM4NWE3ZGEyMzg2Yjk5MjU3ZmVkMjk1N2QyZTRjZGY5NmIwZTg2M2ZhYTc4MmY4NTA4NjU0N2Y0ODA5NiIsIml0ZW1zIjpbW3siYiI6MjEsIm4iOjIyLCJzIjoiZDhkODkyNDJkYTVhMWRjZDJlNzM5OTc0OGE3YWNlMmE1OTdiZGUyYjk2OWY0YzI5M2NmNTNhMDNlMmI0NTE0OCIsInQiOiI0MDllMzczMzViZTk4YzRiODM1ZjE0ZGVjN2NlYzIxYTA1ODU3ZDBkOGMwZDExZmMzYmNjNzMwNGYyM2Q5OGQyIn0seyJiIjoyNSwibiI6MTAsInMiOiJjZTNhY2ZmYzUxYTYzMGQ3Mzc3MGRmOWQ2N2U1YTRiODNjODIxZTI4ODQ4N2QzMjM1MDQ1MzExYjc1ZDFlOWNiIiwidCI6ImNjMGIzMDliYTFkODllNjUwOGZlZmU5ZWM1YTQzYzI0Yjg5NjBmYzk5MjIzNDMwNWRkZGNkNGVhMGY1MTU3YjEifSx7ImIiOjI2LCJuIjozMiwicyI6IjkzMzhjMDEzYTM1MTExNDU3ZjA5MmQ4ZjNlZjhhODQzOGZkMDExNmRhNTdmNDVjZmNlMmY1ZWIxYjkyZDk5MmUiLCJ0IjoiZjBlNWJiODU4MjY3OTM5MTRjYjMxNTUxZjBkNmFhYjZlNWRmMzNhODE4YTI2OGM1NzQ3NDY1YjU1ZWU4MzdhOCJ9XSxbeyJiIjowLCJuIjoxOSwicyI6ImUzYjBjNDQyOThmYzFjMTQ5YWZiZjRjODk5NmZiOTI0MjdhZTQxZTQ2NDliOTM0Y2E0OTU5OTFiNzg1MmI4NTUiLCJ0IjoiODZjODIwMGVjMzgwNTQ3ZTZhOTYwNTIwZmE0NzZiNWU4M2QwOGI1MjdjNjE4ZjY1MDM1MmI2NTZhOWJlNjk0ZiJ9LHsiYiI6MywibiI6MjMsInMiOiI2NmE2NzU3MTUxZjhlZTU1ZGIxMjc3MTZjN2UzZGNlMGJlODA3NGI2NGUyMGVkYTU0MmU1YzFlNDZjYTljNDFlIiwidCI6ImVmMGI2OTk2MDk4MjgyNWRmMTMzY2UwYWViZTIxZTA4MjgyYjk1MzQzMTI0MzQ2NGQyN2Q5MWFkNjRiNTE1YTgifV1dLCJwdWIiOjIxNDc0ODM2NDcsInJvbGUiOiJvcmlnaW5hbCIsInYiOjF9LCJib2FyZCI6ImNvbS5wYXJsYS5iMjUucHJpdmF0ZS4xMjM0NTY3OC0xMjM0LTQyMzQtODIzNC0xMjM0NTY3ODlhYmMuYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsImNhc2VOdW1iZXIiOjEsIm5vbmNlIjoiYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsIm5vdEJlZm9yZU1zIjowLCJvcCI6ImNvbW1pdE9yaWdpbmFsQmFzZWxpbmUiLCJvd25lckV4aXRlZCI6ZmFsc2UsInJ1bklEIjoiMTIzNDU2NzgtMTIzNC00MjM0LTgyMzQtMTIzNDU2Nzg5YWJjIiwic2VxdWVuY2UiOjIuMCwidmVyc2lvbiI6MX0="))))
        XCTAssertThrowsError(try B25Schema.command(XCTUnwrap(Data(base64Encoded: "eyJiYXNlbGluZSI6eyJhZnRlciI6MjE0NzQ4MzY0NywiYmVmb3JlIjoyMTQ3NDgzNjQ3LCJjIjoxLCJjbGVhciI6MjE0NzQ4MzY0NiwiZGlnZXN0IjoiZTBkOGM4NWE3ZGEyMzg2Yjk5MjU3ZmVkMjk1N2QyZTRjZGY5NmIwZTg2M2ZhYTc4MmY4NTA4NjU0N2Y0ODA5NiIsIml0ZW1zIjpbW3siYiI6MjEsIm4iOjIyLCJzIjoiZDhkODkyNDJkYTVhMWRjZDJlNzM5OTc0OGE3YWNlMmE1OTdiZGUyYjk2OWY0YzI5M2NmNTNhMDNlMmI0NTE0OCIsInQiOiI0MDllMzczMzViZTk4YzRiODM1ZjE0ZGVjN2NlYzIxYTA1ODU3ZDBkOGMwZDExZmMzYmNjNzMwNGYyM2Q5OGQyIn0seyJiIjoyNSwibiI6MTAsInMiOiJjZTNhY2ZmYzUxYTYzMGQ3Mzc3MGRmOWQ2N2U1YTRiODNjODIxZTI4ODQ4N2QzMjM1MDQ1MzExYjc1ZDFlOWNiIiwidCI6ImNjMGIzMDliYTFkODllNjUwOGZlZmU5ZWM1YTQzYzI0Yjg5NjBmYzk5MjIzNDMwNWRkZGNkNGVhMGY1MTU3YjEifSx7ImIiOjI2LCJuIjozMiwicyI6IjkzMzhjMDEzYTM1MTExNDU3ZjA5MmQ4ZjNlZjhhODQzOGZkMDExNmRhNTdmNDVjZmNlMmY1ZWIxYjkyZDk5MmUiLCJ0IjoiZjBlNWJiODU4MjY3OTM5MTRjYjMxNTUxZjBkNmFhYjZlNWRmMzNhODE4YTI2OGM1NzQ3NDY1YjU1ZWU4MzdhOCJ9XSxbeyJiIjowLCJuIjoxOSwicyI6ImUzYjBjNDQyOThmYzFjMTQ5YWZiZjRjODk5NmZiOTI0MjdhZTQxZTQ2NDliOTM0Y2E0OTU5OTFiNzg1MmI4NTUiLCJ0IjoiODZjODIwMGVjMzgwNTQ3ZTZhOTYwNTIwZmE0NzZiNWU4M2QwOGI1MjdjNjE4ZjY1MDM1MmI2NTZhOWJlNjk0ZiJ9LHsiYiI6MywibiI6MjMsInMiOiI2NmE2NzU3MTUxZjhlZTU1ZGIxMjc3MTZjN2UzZGNlMGJlODA3NGI2NGUyMGVkYTU0MmU1YzFlNDZjYTljNDFlIiwidCI6ImVmMGI2OTk2MDk4MjgyNWRmMTMzY2UwYWViZTIxZTA4MjgyYjk1MzQzMTI0MzQ2NGQyN2Q5MWFkNjRiNTE1YTgifV1dLCJwdWIiOjIxNDc0ODM2NDcsInJvbGUiOiJvcmlnaW5hbCIsInYiOjF9LCJib2FyZCI6ImNvbS5wYXJsYS5iMjUucHJpdmF0ZS4xMjM0NTY3OC0xMjM0LTQyMzQtODIzNC0xMjM0NTY3ODlhYmMuYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsImNhc2VOdW1iZXIiOjEsIm5vbmNlIjoiYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsIm5vdEJlZm9yZU1zIjowLCJvcCI6ImNvbW1pdE9yaWdpbmFsQmFzZWxpbmUiLCJvd25lckV4aXRlZCI6ZmFsc2UsInJ1bklEIjoiMTIzNDU2NzgtMTIzNC00MjM0LTgyMzQtMTIzNDU2Nzg5YWJjIiwic2VxdWVuY2UiOjIxNDc0ODM2NDgsInZlcnNpb24iOjF9"))))
        XCTAssertThrowsError(try B25Schema.command(XCTUnwrap(Data(base64Encoded: "eyJiYXNlbGluZSI6eyJhZnRlciI6MjE0NzQ4MzY0NywiYmVmb3JlIjoyMTQ3NDgzNjQ3LCJjIjoxLCJjbGVhciI6MjE0NzQ4MzY0NiwiZGlnZXN0IjoiZTBkOGM4NWE3ZGEyMzg2Yjk5MjU3ZmVkMjk1N2QyZTRjZGY5NmIwZTg2M2ZhYTc4MmY4NTA4NjU0N2Y0ODA5NiIsIml0ZW1zIjpbW3siYiI6MjEsIm4iOjIyLCJzIjoiZDhkODkyNDJkYTVhMWRjZDJlNzM5OTc0OGE3YWNlMmE1OTdiZGUyYjk2OWY0YzI5M2NmNTNhMDNlMmI0NTE0OCIsInQiOiI0MDllMzczMzViZTk4YzRiODM1ZjE0ZGVjN2NlYzIxYTA1ODU3ZDBkOGMwZDExZmMzYmNjNzMwNGYyM2Q5OGQyIn0seyJiIjoyNSwibiI6MTAsInMiOiJjZTNhY2ZmYzUxYTYzMGQ3Mzc3MGRmOWQ2N2U1YTRiODNjODIxZTI4ODQ4N2QzMjM1MDQ1MzExYjc1ZDFlOWNiIiwidCI6ImNjMGIzMDliYTFkODllNjUwOGZlZmU5ZWM1YTQzYzI0Yjg5NjBmYzk5MjIzNDMwNWRkZGNkNGVhMGY1MTU3YjEifSx7ImIiOjI2LCJuIjozMiwicyI6IjkzMzhjMDEzYTM1MTExNDU3ZjA5MmQ4ZjNlZjhhODQzOGZkMDExNmRhNTdmNDVjZmNlMmY1ZWIxYjkyZDk5MmUiLCJ0IjoiZjBlNWJiODU4MjY3OTM5MTRjYjMxNTUxZjBkNmFhYjZlNWRmMzNhODE4YTI2OGM1NzQ3NDY1YjU1ZWU4MzdhOCJ9XSxbeyJiIjowLCJuIjoxOSwicyI6ImUzYjBjNDQyOThmYzFjMTQ5YWZiZjRjODk5NmZiOTI0MjdhZTQxZTQ2NDliOTM0Y2E0OTU5OTFiNzg1MmI4NTUiLCJ0IjoiODZjODIwMGVjMzgwNTQ3ZTZhOTYwNTIwZmE0NzZiNWU4M2QwOGI1MjdjNjE4ZjY1MDM1MmI2NTZhOWJlNjk0ZiJ9LHsiYiI6MywibiI6MjMsInMiOiI2NmE2NzU3MTUxZjhlZTU1ZGIxMjc3MTZjN2UzZGNlMGJlODA3NGI2NGUyMGVkYTU0MmU1YzFlNDZjYTljNDFlIiwidCI6ImVmMGI2OTk2MDk4MjgyNWRmMTMzY2UwYWViZTIxZTA4MjgyYjk1MzQzMTI0MzQ2NGQyN2Q5MWFkNjRiNTE1YTgifV1dLCJwdWIiOjIxNDc0ODM2NDcsInJvbGUiOiJvcmlnaW5hbCIsInYiOjF9LCJib2FyZCI6ImNvbS5wYXJsYS5iMjUucHJpdmF0ZS4xMjM0NTY3OC0xMjM0LTQyMzQtODIzNC0xMjM0NTY3ODlhYmMuYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsImNhc2VOdW1iZXIiOjEsIm5vbmNlIjoiYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsIm5vdEJlZm9yZU1zIjowLCJvcCI6ImNvbW1pdE9yaWdpbmFsQmFzZWxpbmUiLCJvd25lckV4aXRlZCI6bnVsbCwicnVuSUQiOiIxMjM0NTY3OC0xMjM0LTQyMzQtODIzNC0xMjM0NTY3ODlhYmMiLCJzZXF1ZW5jZSI6MiwidmVyc2lvbiI6MX0="))))
        XCTAssertThrowsError(try B25Schema.command(XCTUnwrap(Data(base64Encoded: "eyJiYXNlbGluZSI6eyJhZnRlciI6MjE0NzQ4MzY0NywiYmVmb3JlIjoyMTQ3NDgzNjQ3LCJjIjoxLCJjbGVhciI6MjE0NzQ4MzY0NiwiZGlnZXN0IjoiZTBkOGM4NWE3ZGEyMzg2Yjk5MjU3ZmVkMjk1N2QyZTRjZGY5NmIwZTg2M2ZhYTc4MmY4NTA4NjU0N2Y0ODA5NiIsIml0ZW1zIjpbW3siYiI6MjEsIm4iOjIyLCJzIjoiZDhkODkyNDJkYTVhMWRjZDJlNzM5OTc0OGE3YWNlMmE1OTdiZGUyYjk2OWY0YzI5M2NmNTNhMDNlMmI0NTE0OCIsInQiOiI0MDllMzczMzViZTk4YzRiODM1ZjE0ZGVjN2NlYzIxYTA1ODU3ZDBkOGMwZDExZmMzYmNjNzMwNGYyM2Q5OGQyIn0seyJiIjoyNSwibiI6MTAsInMiOiJjZTNhY2ZmYzUxYTYzMGQ3Mzc3MGRmOWQ2N2U1YTRiODNjODIxZTI4ODQ4N2QzMjM1MDQ1MzExYjc1ZDFlOWNiIiwidCI6ImNjMGIzMDliYTFkODllNjUwOGZlZmU5ZWM1YTQzYzI0Yjg5NjBmYzk5MjIzNDMwNWRkZGNkNGVhMGY1MTU3YjEifSx7ImIiOjI2LCJuIjozMiwicyI6IjkzMzhjMDEzYTM1MTExNDU3ZjA5MmQ4ZjNlZjhhODQzOGZkMDExNmRhNTdmNDVjZmNlMmY1ZWIxYjkyZDk5MmUiLCJ0IjoiZjBlNWJiODU4MjY3OTM5MTRjYjMxNTUxZjBkNmFhYjZlNWRmMzNhODE4YTI2OGM1NzQ3NDY1YjU1ZWU4MzdhOCJ9XSxbeyJiIjowLCJuIjoxOSwicyI6ImUzYjBjNDQyOThmYzFjMTQ5YWZiZjRjODk5NmZiOTI0MjdhZTQxZTQ2NDliOTM0Y2E0OTU5OTFiNzg1MmI4NTUiLCJ0IjoiODZjODIwMGVjMzgwNTQ3ZTZhOTYwNTIwZmE0NzZiNWU4M2QwOGI1MjdjNjE4ZjY1MDM1MmI2NTZhOWJlNjk0ZiJ9LHsiYiI6MywibiI6MjMsInMiOiI2NmE2NzU3MTUxZjhlZTU1ZGIxMjc3MTZjN2UzZGNlMGJlODA3NGI2NGUyMGVkYTU0MmU1YzFlNDZjYTljNDFlIiwidCI6ImVmMGI2OTk2MDk4MjgyNWRmMTMzY2UwYWViZTIxZTA4MjgyYjk1MzQzMTI0MzQ2NGQyN2Q5MWFkNjRiNTE1YTgifV1dLCJwdWIiOjIxNDc0ODM2NDcsInJvbGUiOiJvcmlnaW5hbCIsInYiOjF9LCJib2FyZCI6ImNvbS5wYXJsYS5iMjUucHJpdmF0ZS4xMjM0NTY3OC0xMjM0LTQyMzQtODIzNC0xMjM0NTY3ODlhYmMuYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsImNhc2VOdW1iZXIiOjEsIm5vbmNlIjoiYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsIm5vdEJlZm9yZU1zIjowLCJvcCI6ImNvbW1pdE9yaWdpbmFsQmFzZWxpbmUiLCJvd25lckV4aXRlZCI6ZmFsc2UsInJ1bklEIjoiMTIzNDU2NzgtMTIzNC00MjM0LTgyMzQtMTIzNDU2Nzg5YWJjIiwic2VxdWVuY2UiOjIsInVua25vd24iOjEsInZlcnNpb24iOjF9"))))
        XCTAssertThrowsError(try B25Schema.command(XCTUnwrap(Data(base64Encoded: "eyJiYXNlbGluZSI6eyJhZnRlciI6MjE0NzQ4MzY0NywiYmVmb3JlIjoyMTQ3NDgzNjQ3LCJjIjoxLCJjbGVhciI6MjE0NzQ4MzY0NiwiZGlnZXN0IjoiZTBkOGM4NWE3ZGEyMzg2Yjk5MjU3ZmVkMjk1N2QyZTRjZGY5NmIwZTg2M2ZhYTc4MmY4NTA4NjU0N2Y0ODA5NiIsIml0ZW1zIjpbW3siYiI6MjEsIm4iOjIyLCJzIjoiZDhkODkyNDJkYTVhMWRjZDJlNzM5OTc0OGE3YWNlMmE1OTdiZGUyYjk2OWY0YzI5M2NmNTNhMDNlMmI0NTE0OCIsInQiOiI0MDllMzczMzViZTk4YzRiODM1ZjE0ZGVjN2NlYzIxYTA1ODU3ZDBkOGMwZDExZmMzYmNjNzMwNGYyM2Q5OGQyIn0seyJiIjoyNSwibiI6MTAsInMiOiJjZTNhY2ZmYzUxYTYzMGQ3Mzc3MGRmOWQ2N2U1YTRiODNjODIxZTI4ODQ4N2QzMjM1MDQ1MzExYjc1ZDFlOWNiIiwidCI6ImNjMGIzMDliYTFkODllNjUwOGZlZmU5ZWM1YTQzYzI0Yjg5NjBmYzk5MjIzNDMwNWRkZGNkNGVhMGY1MTU3YjEifSx7ImIiOjI2LCJuIjozMiwicyI6IjkzMzhjMDEzYTM1MTExNDU3ZjA5MmQ4ZjNlZjhhODQzOGZkMDExNmRhNTdmNDVjZmNlMmY1ZWIxYjkyZDk5MmUiLCJ0IjoiZjBlNWJiODU4MjY3OTM5MTRjYjMxNTUxZjBkNmFhYjZlNWRmMzNhODE4YTI2OGM1NzQ3NDY1YjU1ZWU4MzdhOCJ9XSxbeyJiIjowLCJuIjoxOSwicyI6ImUzYjBjNDQyOThmYzFjMTQ5YWZiZjRjODk5NmZiOTI0MjdhZTQxZTQ2NDliOTM0Y2E0OTU5OTFiNzg1MmI4NTUiLCJ0IjoiODZjODIwMGVjMzgwNTQ3ZTZhOTYwNTIwZmE0NzZiNWU4M2QwOGI1MjdjNjE4ZjY1MDM1MmI2NTZhOWJlNjk0ZiJ9LHsiYiI6MywibiI6MjMsInMiOiI2NmE2NzU3MTUxZjhlZTU1ZGIxMjc3MTZjN2UzZGNlMGJlODA3NGI2NGUyMGVkYTU0MmU1YzFlNDZjYTljNDFlIiwidCI6ImVmMGI2OTk2MDk4MjgyNWRmMTMzY2UwYWViZTIxZTA4MjgyYjk1MzQzMTI0MzQ2NGQyN2Q5MWFkNjRiNTE1YTgifV1dLCJwdWIiOjIxNDc0ODM2NDcsInJvbGUiOiJvcmlnaW5hbCIsInYiOjF9LCJib2FyZCI6ImNvbS5wYXJsYS5iMjUucHJpdmF0ZS4xMjM0NTY3OC0xMjM0LTQyMzQtODIzNC0xMjM0NTY3ODlhYmMuYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsImNhc2VOdW1iZXIiOjEsIm5vbmNlIjoiYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsIm5vdEJlZm9yZU1zIjowLCJvcCI6ImNvbW1pdE9yaWdpbmFsQmFzZWxpbmUiLCJvd25lckV4aXRlZCI6ZmFsc2UsInJ1bklEIjoiMTIzNDU2NzgtMTIzNC00MjM0LTgyMzQtMTIzNDU2Nzg5YWJjIiwic2VxdWVuY2UiOjIsInZlcnNpb24iOjEsInNlcXVlbmNlIjoyfQ=="))))
        // Frozen32-character finite-time vectors shared with the pure codec; metadata only.
        let wide0 = try XCTUnwrap(Data(base64Encoded: "eyJiYXNlbGluZSI6eyJhZnRlciI6MjE0NzQ4MzY0NywiYmVmb3JlIjoyMTQ3NDgzNjQ3LCJjIjoxLCJjbGVhciI6MjE0NzQ4MzY0NiwiZGlnZXN0IjoiZTBkOGM4NWE3ZGEyMzg2Yjk5MjU3ZmVkMjk1N2QyZTRjZGY5NmIwZTg2M2ZhYTc4MmY4NTA4NjU0N2Y0ODA5NiIsIml0ZW1zIjpbW3siYiI6MjEsIm4iOjIyLCJzIjoiZDhkODkyNDJkYTVhMWRjZDJlNzM5OTc0OGE3YWNlMmE1OTdiZGUyYjk2OWY0YzI5M2NmNTNhMDNlMmI0NTE0OCIsInQiOiI0MDllMzczMzViZTk4YzRiODM1ZjE0ZGVjN2NlYzIxYTA1ODU3ZDBkOGMwZDExZmMzYmNjNzMwNGYyM2Q5OGQyIn0seyJiIjoyNSwibiI6MTAsInMiOiJjZTNhY2ZmYzUxYTYzMGQ3Mzc3MGRmOWQ2N2U1YTRiODNjODIxZTI4ODQ4N2QzMjM1MDQ1MzExYjc1ZDFlOWNiIiwidCI6ImNjMGIzMDliYTFkODllNjUwOGZlZmU5ZWM1YTQzYzI0Yjg5NjBmYzk5MjIzNDMwNWRkZGNkNGVhMGY1MTU3YjEifSx7ImIiOjI2LCJuIjozMiwicyI6IjkzMzhjMDEzYTM1MTExNDU3ZjA5MmQ4ZjNlZjhhODQzOGZkMDExNmRhNTdmNDVjZmNlMmY1ZWIxYjkyZDk5MmUiLCJ0IjoiZjBlNWJiODU4MjY3OTM5MTRjYjMxNTUxZjBkNmFhYjZlNWRmMzNhODE4YTI2OGM1NzQ3NDY1YjU1ZWU4MzdhOCJ9XSxbeyJiIjowLCJuIjoxOSwicyI6ImUzYjBjNDQyOThmYzFjMTQ5YWZiZjRjODk5NmZiOTI0MjdhZTQxZTQ2NDliOTM0Y2E0OTU5OTFiNzg1MmI4NTUiLCJ0IjoiODZjODIwMGVjMzgwNTQ3ZTZhOTYwNTIwZmE0NzZiNWU4M2QwOGI1MjdjNjE4ZjY1MDM1MmI2NTZhOWJlNjk0ZiJ9LHsiYiI6MywibiI6MjMsInMiOiI2NmE2NzU3MTUxZjhlZTU1ZGIxMjc3MTZjN2UzZGNlMGJlODA3NGI2NGUyMGVkYTU0MmU1YzFlNDZjYTljNDFlIiwidCI6ImVmMGI2OTk2MDk4MjgyNWRmMTMzY2UwYWViZTIxZTA4MjgyYjk1MzQzMTI0MzQ2NGQyN2Q5MWFkNjRiNTE1YTgifV1dLCJwdWIiOjIxNDc0ODM2NDcsInJvbGUiOiJvcmlnaW5hbCIsInYiOjF9LCJib2FyZCI6ImNvbS5wYXJsYS5iMjUucHJpdmF0ZS4xMjM0NTY3OC0xMjM0LTQyMzQtODIzNC0xMjM0NTY3ODlhYmMuYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsImNhc2VOdW1iZXIiOjEsIm5vbmNlIjoiYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsIm5vdEJlZm9yZU1zIjowLjAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMCwib3AiOiJjb21taXRPcmlnaW5hbEJhc2VsaW5lIiwib3duZXJFeGl0ZWQiOmZhbHNlLCJydW5JRCI6IjEyMzQ1Njc4LTEyMzQtNDIzNC04MjM0LTEyMzQ1Njc4OWFiYyIsInNlcXVlbmNlIjoyLCJ2ZXJzaW9uIjoxfQ=="))
        _ = try B25Schema.command(wide0)
        let wide1 = try XCTUnwrap(Data(base64Encoded: "eyJhY2NlcHRlZCI6dHJ1ZSwiYm9hcmQiOiJjb20ucGFybGEuYjI1LnByaXZhdGUuMTIzNDU2NzgtMTIzNC00MjM0LTgyMzQtMTIzNDU2Nzg5YWJjLmFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWEiLCJjYXNlTnVtYmVyIjoxLCJkYXRhUmVhZHMiOjAsImRpZ2VzdCI6ImUwZDhjODVhN2RhMjM4NmI5OTI1N2ZlZDI5NTdkMmU0Y2RmOTZiMGU4NjNmYWE3ODJmODUwODY1NDdmNDgwOTYiLCJlbmRNcyI6MTAwMDAwMDAwMDAwMC4wMDAwMDAwMDAwMDAwMDAwMDAsImtpbmQiOiJtZXRhZGF0YUFjayIsIm5vbmNlIjoiYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsIm9wIjoiY29tbWl0T3JpZ2luYWxCYXNlbGluZSIsInJvbGUiOiJvcmlnaW5hbCIsInJ1bklEIjoiMTIzNDU2NzgtMTIzNC00MjM0LTgyMzQtMTIzNDU2Nzg5YWJjIiwic2VxdWVuY2UiOjIsInN0YXJ0TXMiOjEwMDAwMDAwMDAwMDAuMDAwMDAwMDAwMDAwMDAwMDAwLCJ2ZXJzaW9uIjoxfQ=="))
        _ = try B25Schema.response(wide1, command: decoded2, now: 1e12, began: 1e12)
        let wide2 = try XCTUnwrap(Data(base64Encoded: "eyJib2FyZCI6ImNvbS5wYXJsYS5iMjUucHJpdmF0ZS4xMjM0NTY3OC0xMjM0LTQyMzQtODIzNC0xMjM0NTY3ODlhYmMuYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsImNhc2VOdW1iZXIiOjYsIm5vbmNlIjoiYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsIm5vdEJlZm9yZU1zIjowLjAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMCwib3AiOiJyZXBsYWNlIiwib3duZXJFeGl0ZWQiOmZhbHNlLCJydW5JRCI6IjEyMzQ1Njc4LTEyMzQtNDIzNC04MjM0LTEyMzQ1Njc4OWFiYyIsInNlcXVlbmNlIjoxOSwidmVyc2lvbiI6MX0="))
        _ = try B25Schema.command(wide2)
        let wide3 = try XCTUnwrap(Data(base64Encoded: "eyJiYXNlbGluZSI6eyJhZnRlciI6MjE0NzQ4MzY0NywiYmVmb3JlIjoyMTQ3NDgzNjQ3LCJjIjo2LCJjbGVhciI6MjE0NzQ4MzY0NiwiZGlnZXN0IjoiZjVkODVlMjhkYzEyN2Y0MjUyNWVjODc3ODI5NTE5OGJmYzc1OGRiMzVjMjA3NDNlYTgxNzExNWZlNjllMDhjOCIsIml0ZW1zIjpbW3siYiI6MjQsIm4iOjIyLCJzIjoiN2UzNzZlZjUxZWVkNzNkNGY0OWQ0NDY0Mjk5NjAwNzVlNjQ4MDMxMjM5YzdjMzQ2ZTNiNGZjN2I3Nzg5YWE2MyIsInQiOiI0MDllMzczMzViZTk4YzRiODM1ZjE0ZGVjN2NlYzIxYTA1ODU3ZDBkOGMwZDExZmMzYmNjNzMwNGYyM2Q5OGQyIn0seyJiIjoyOCwibiI6MTAsInMiOiI1MjFjNjA0YmI1OTk4MWQxOTYyNTU2ZDk5YWI2M2ExODVjZGQyNzNmODJiNzc4YzIzYzI4NDkzZTUyY2JjZjY3IiwidCI6ImNjMGIzMDliYTFkODllNjUwOGZlZmU5ZWM1YTQzYzI0Yjg5NjBmYzk5MjIzNDMwNWRkZGNkNGVhMGY1MTU3YjEifSx7ImIiOjY1NDgxLCJuIjozMiwicyI6IjkzMzhjMDEzYTM1MTExNDU3ZjA5MmQ4ZjNlZjhhODQzOGZkMDExNmRhNTdmNDVjZmNlMmY1ZWIxYjkyZDk5MmUiLCJ0IjoiZjBlNWJiODU4MjY3OTM5MTRjYjMxNTUxZjBkNmFhYjZlNWRmMzNhODE4YTI2OGM1NzQ3NDY1YjU1ZWU4MzdhOCJ9XSxbeyJiIjowLCJuIjoxOSwicyI6ImUzYjBjNDQyOThmYzFjMTQ5YWZiZjRjODk5NmZiOTI0MjdhZTQxZTQ2NDliOTM0Y2E0OTU5OTFiNzg1MmI4NTUiLCJ0IjoiODZjODIwMGVjMzgwNTQ3ZTZhOTYwNTIwZmE0NzZiNWU4M2QwOGI1MjdjNjE4ZjY1MDM1MmI2NTZhOWJlNjk0ZiJ9LHsiYiI6MywibiI6MjMsInMiOiI4ZTg5OGJlNmQyYzkyNjc1ZjZkNjQ2MjU5NTcxYmM5OTBmZDMwZmNjZGRiNzM5MTNhOThkNWYwNjA3NDIwNWQ2IiwidCI6ImVmMGI2OTk2MDk4MjgyNWRmMTMzY2UwYWViZTIxZTA4MjgyYjk1MzQzMTI0MzQ2NGQyN2Q5MWFkNjRiNTE1YTgifV1dLCJwdWIiOjIxNDc0ODM2NDcsInJvbGUiOiJyZXBsYWNlbWVudCIsInYiOjF9LCJib2FyZCI6ImNvbS5wYXJsYS5iMjUucHJpdmF0ZS4xMjM0NTY3OC0xMjM0LTQyMzQtODIzNC0xMjM0NTY3ODlhYmMuYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsImNhc2VOdW1iZXIiOjYsImNoYW5nZUNvdW50IjoyMTQ3NDgzNjQ3LCJlbmRNcyI6MTAwMDAwMDAwMDAwMC4wMDAwMDAwMDAwMDAwMDAwMDAsImVxdWFsaXR5Ijp0cnVlLCJpdGVtQ291bnQiOjIsImtpbmQiOiJuYXRpdmUiLCJub25jZSI6ImFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWEiLCJvayI6dHJ1ZSwib3AiOiJyZXBsYWNlIiwicmVhZHMiOjUsInJlcHJlc2VudGF0aW9uQ291bnQiOjUsInJ1bklEIjoiMTIzNDU2NzgtMTIzNC00MjM0LTgyMzQtMTIzNDU2Nzg5YWJjIiwic2VxdWVuY2UiOjE5LCJzdGFydE1zIjoxMDAwMDAwMDAwMDAwLjAwMDAwMDAwMDAwMDAwMDAwMCwidmVyc2lvbiI6MX0="))
        _ = try B25Schema.response(wide3, command: decoded19, now: 1e12, began: 1e12)
        let wide4 = try XCTUnwrap(Data(base64Encoded: "eyJiYXNlbGluZSI6eyJhZnRlciI6MjE0NzQ4MzY0NywiYmVmb3JlIjoyMTQ3NDgzNjQ3LCJjIjo3LCJjbGVhciI6MjE0NzQ4MzY0NiwiZGlnZXN0IjoiOThjYWUxMmUzOTcxMTRjMDgyYzcxNGMwYzk2OGQwODEyYzI1NzQwOTViOTk3ZDljZWZiODIyZTFkNGU0YjE0ZSIsIml0ZW1zIjpbW3siYiI6MjEsIm4iOjIyLCJzIjoiZDhkODkyNDJkYTVhMWRjZDJlNzM5OTc0OGE3YWNlMmE1OTdiZGUyYjk2OWY0YzI5M2NmNTNhMDNlMmI0NTE0OCIsInQiOiI0MDllMzczMzViZTk4YzRiODM1ZjE0ZGVjN2NlYzIxYTA1ODU3ZDBkOGMwZDExZmMzYmNjNzMwNGYyM2Q5OGQyIn0seyJiIjoyNSwibiI6MTAsInMiOiJjZTNhY2ZmYzUxYTYzMGQ3Mzc3MGRmOWQ2N2U1YTRiODNjODIxZTI4ODQ4N2QzMjM1MDQ1MzExYjc1ZDFlOWNiIiwidCI6ImNjMGIzMDliYTFkODllNjUwOGZlZmU5ZWM1YTQzYzI0Yjg5NjBmYzk5MjIzNDMwNWRkZGNkNGVhMGY1MTU3YjEifSx7ImIiOjI2LCJuIjozMiwicyI6IjkzMzhjMDEzYTM1MTExNDU3ZjA5MmQ4ZjNlZjhhODQzOGZkMDExNmRhNTdmNDVjZmNlMmY1ZWIxYjkyZDk5MmUiLCJ0IjoiZjBlNWJiODU4MjY3OTM5MTRjYjMxNTUxZjBkNmFhYjZlNWRmMzNhODE4YTI2OGM1NzQ3NDY1YjU1ZWU4MzdhOCJ9XSxbeyJiIjowLCJuIjoxOSwicyI6ImUzYjBjNDQyOThmYzFjMTQ5YWZiZjRjODk5NmZiOTI0MjdhZTQxZTQ2NDliOTM0Y2E0OTU5OTFiNzg1MmI4NTUiLCJ0IjoiODZjODIwMGVjMzgwNTQ3ZTZhOTYwNTIwZmE0NzZiNWU4M2QwOGI1MjdjNjE4ZjY1MDM1MmI2NTZhOWJlNjk0ZiJ9LHsiYiI6MywibiI6MjMsInMiOiI2NmE2NzU3MTUxZjhlZTU1ZGIxMjc3MTZjN2UzZGNlMGJlODA3NGI2NGUyMGVkYTU0MmU1YzFlNDZjYTljNDFlIiwidCI6ImVmMGI2OTk2MDk4MjgyNWRmMTMzY2UwYWViZTIxZTA4MjgyYjk1MzQzMTI0MzQ2NGQyN2Q5MWFkNjRiNTE1YTgifV1dLCJwdWIiOjIxNDc0ODM2NDcsInJvbGUiOiJvcmlnaW5hbCIsInYiOjF9LCJib2FyZCI6ImNvbS5wYXJsYS5iMjUucHJpdmF0ZS4xMjM0NTY3OC0xMjM0LTQyMzQtODIzNC0xMjM0NTY3ODlhYmMuYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsImNhc2VOdW1iZXIiOjcsIm5vbmNlIjoiYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsIm5vdEJlZm9yZU1zIjowLjAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMCwib3AiOiJjb21taXRPcmlnaW5hbEJhc2VsaW5lIiwib3duZXJFeGl0ZWQiOmZhbHNlLCJydW5JRCI6IjEyMzQ1Njc4LTEyMzQtNDIzNC04MjM0LTEyMzQ1Njc4OWFiYyIsInNlcXVlbmNlIjoyMSwidmVyc2lvbiI6MX0="))
        _ = try B25Schema.command(wide4)
        let wide5 = try XCTUnwrap(Data(base64Encoded: "eyJhY2NlcHRlZCI6dHJ1ZSwiYm9hcmQiOiJjb20ucGFybGEuYjI1LnByaXZhdGUuMTIzNDU2NzgtMTIzNC00MjM0LTgyMzQtMTIzNDU2Nzg5YWJjLmFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWEiLCJjYXNlTnVtYmVyIjo3LCJkYXRhUmVhZHMiOjAsImRpZ2VzdCI6Ijk4Y2FlMTJlMzk3MTE0YzA4MmM3MTRjMGM5NjhkMDgxMmMyNTc0MDk1Yjk5N2Q5Y2VmYjgyMmUxZDRlNGIxNGUiLCJlbmRNcyI6MTAwMDAwMDAwMDAwMC4wMDAwMDAwMDAwMDAwMDAwMDAsImtpbmQiOiJtZXRhZGF0YUFjayIsIm5vbmNlIjoiYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsIm9wIjoiY29tbWl0T3JpZ2luYWxCYXNlbGluZSIsInJvbGUiOiJvcmlnaW5hbCIsInJ1bklEIjoiMTIzNDU2NzgtMTIzNC00MjM0LTgyMzQtMTIzNDU2Nzg5YWJjIiwic2VxdWVuY2UiOjIxLCJzdGFydE1zIjoxMDAwMDAwMDAwMDAwLjAwMDAwMDAwMDAwMDAwMDAwMCwidmVyc2lvbiI6MX0="))
        _ = try B25Schema.response(wide5, command: decoded21, now: 1e12, began: 1e12)
        let wide6 = try XCTUnwrap(Data(base64Encoded: "eyJhY2NlcHRlZCI6ZmFsc2UsImJvYXJkIjoiY29tLnBhcmxhLmIyNS5wcml2YXRlLjEyMzQ1Njc4LTEyMzQtNDIzNC04MjM0LTEyMzQ1Njc4OWFiYy5hYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhIiwiY2FzZU51bWJlciI6MSwiZGF0YVJlYWRzIjowLCJkaWdlc3QiOiJlMGQ4Yzg1YTdkYTIzODZiOTkyNTdmZWQyOTU3ZDJlNGNkZjk2YjBlODYzZmFhNzgyZjg1MDg2NTQ3ZjQ4MDk2IiwiZW5kTXMiOjEwMDAwMDAwMDAwMDAuMDAwMDAwMDAwMDAwMDAwMDAwLCJraW5kIjoibWV0YWRhdGFBY2siLCJub25jZSI6ImFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWEiLCJvcCI6ImNvbW1pdE9yaWdpbmFsQmFzZWxpbmUiLCJyb2xlIjoib3JpZ2luYWwiLCJydW5JRCI6IjEyMzQ1Njc4LTEyMzQtNDIzNC04MjM0LTEyMzQ1Njc4OWFiYyIsInNlcXVlbmNlIjoyLCJzdGFydE1zIjoxMDAwMDAwMDAwMDAwLjAwMDAwMDAwMDAwMDAwMDAwMCwidmVyc2lvbiI6MX0="))
        _ = try B25Schema.response(wide6, command: decoded2, now: 1e12, began: 1e12)
        let wide7 = try XCTUnwrap(Data(base64Encoded: "eyJiYXNlbGluZSI6eyJhZnRlciI6MjE0NzQ4MzY0NywiYmVmb3JlIjoyMTQ3NDgzNjQ3LCJjIjo2LCJjbGVhciI6MjE0NzQ4MzY0NiwiZGlnZXN0IjoiZjVkODVlMjhkYzEyN2Y0MjUyNWVjODc3ODI5NTE5OGJmYzc1OGRiMzVjMjA3NDNlYTgxNzExNWZlNjllMDhjOCIsIml0ZW1zIjpbW3siYiI6MjQsIm4iOjIyLCJzIjoiN2UzNzZlZjUxZWVkNzNkNGY0OWQ0NDY0Mjk5NjAwNzVlNjQ4MDMxMjM5YzdjMzQ2ZTNiNGZjN2I3Nzg5YWE2MyIsInQiOiI0MDllMzczMzViZTk4YzRiODM1ZjE0ZGVjN2NlYzIxYTA1ODU3ZDBkOGMwZDExZmMzYmNjNzMwNGYyM2Q5OGQyIn0seyJiIjoyOCwibiI6MTAsInMiOiI1MjFjNjA0YmI1OTk4MWQxOTYyNTU2ZDk5YWI2M2ExODVjZGQyNzNmODJiNzc4YzIzYzI4NDkzZTUyY2JjZjY3IiwidCI6ImNjMGIzMDliYTFkODllNjUwOGZlZmU5ZWM1YTQzYzI0Yjg5NjBmYzk5MjIzNDMwNWRkZGNkNGVhMGY1MTU3YjEifSx7ImIiOjY1NDgxLCJuIjozMiwicyI6IjkzMzhjMDEzYTM1MTExNDU3ZjA5MmQ4ZjNlZjhhODQzOGZkMDExNmRhNTdmNDVjZmNlMmY1ZWIxYjkyZDk5MmUiLCJ0IjoiZjBlNWJiODU4MjY3OTM5MTRjYjMxNTUxZjBkNmFhYjZlNWRmMzNhODE4YTI2OGM1NzQ3NDY1YjU1ZWU4MzdhOCJ9XSxbeyJiIjowLCJuIjoxOSwicyI6ImUzYjBjNDQyOThmYzFjMTQ5YWZiZjRjODk5NmZiOTI0MjdhZTQxZTQ2NDliOTM0Y2E0OTU5OTFiNzg1MmI4NTUiLCJ0IjoiODZjODIwMGVjMzgwNTQ3ZTZhOTYwNTIwZmE0NzZiNWU4M2QwOGI1MjdjNjE4ZjY1MDM1MmI2NTZhOWJlNjk0ZiJ9LHsiYiI6MywibiI6MjMsInMiOiI4ZTg5OGJlNmQyYzkyNjc1ZjZkNjQ2MjU5NTcxYmM5OTBmZDMwZmNjZGRiNzM5MTNhOThkNWYwNjA3NDIwNWQ2IiwidCI6ImVmMGI2OTk2MDk4MjgyNWRmMTMzY2UwYWViZTIxZTA4MjgyYjk1MzQzMTI0MzQ2NGQyN2Q5MWFkNjRiNTE1YTgifV1dLCJwdWIiOjIxNDc0ODM2NDcsInJvbGUiOiJyZXBsYWNlbWVudCIsInYiOjF9LCJib2FyZCI6ImNvbS5wYXJsYS5iMjUucHJpdmF0ZS4xMjM0NTY3OC0xMjM0LTQyMzQtODIzNC0xMjM0NTY3ODlhYmMuYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsImNhc2VOdW1iZXIiOjYsImNoYW5nZUNvdW50IjoyMTQ3NDgzNjQ3LCJlbmRNcyI6MTAwMDAwMDAwMDAwMC4wMDAwMDAwMDAwMDAwMDAwMDAsImVxdWFsaXR5IjpmYWxzZSwiaXRlbUNvdW50IjoyLCJraW5kIjoibmF0aXZlIiwibm9uY2UiOiJhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhIiwib2siOmZhbHNlLCJvcCI6InJlcGxhY2UiLCJyZWFkcyI6MTAsInJlcHJlc2VudGF0aW9uQ291bnQiOjUsInJ1bklEIjoiMTIzNDU2NzgtMTIzNC00MjM0LTgyMzQtMTIzNDU2Nzg5YWJjIiwic2VxdWVuY2UiOjE5LCJzdGFydE1zIjoxMDAwMDAwMDAwMDAwLjAwMDAwMDAwMDAwMDAwMDAwMCwidmVyc2lvbiI6MX0="))
        _ = try B25Schema.response(wide7, command: decoded19, now: 1e12, began: 1e12)
        let wide8 = try XCTUnwrap(Data(base64Encoded: "eyJhY2NlcHRlZCI6ZmFsc2UsImJvYXJkIjoiY29tLnBhcmxhLmIyNS5wcml2YXRlLjEyMzQ1Njc4LTEyMzQtNDIzNC04MjM0LTEyMzQ1Njc4OWFiYy5hYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhIiwiY2FzZU51bWJlciI6NywiZGF0YVJlYWRzIjowLCJkaWdlc3QiOiI5OGNhZTEyZTM5NzExNGMwODJjNzE0YzBjOTY4ZDA4MTJjMjU3NDA5NWI5OTdkOWNlZmI4MjJlMWQ0ZTRiMTRlIiwiZW5kTXMiOjEwMDAwMDAwMDAwMDAuMDAwMDAwMDAwMDAwMDAwMDAwLCJraW5kIjoibWV0YWRhdGFBY2siLCJub25jZSI6ImFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWEiLCJvcCI6ImNvbW1pdE9yaWdpbmFsQmFzZWxpbmUiLCJyb2xlIjoib3JpZ2luYWwiLCJydW5JRCI6IjEyMzQ1Njc4LTEyMzQtNDIzNC04MjM0LTEyMzQ1Njc4OWFiYyIsInNlcXVlbmNlIjoyMSwic3RhcnRNcyI6MTAwMDAwMDAwMDAwMC4wMDAwMDAwMDAwMDAwMDAwMDAsInZlcnNpb24iOjF9"))
        _ = try B25Schema.response(wide8, command: decoded21, now: 1e12, began: 1e12)
        XCTAssertEqual(B25Schema.steps.count,25)
        XCTAssertEqual(B25Schema.caps,[6,8,6,6,5,10,1,5])
    }
}
