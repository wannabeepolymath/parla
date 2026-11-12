import Foundation
import Darwin

// Advisory OS lock covers the entire read/modify/atomic-write transaction across processes.
// No UserDefaults session cache, no split writers, and no API key in the shared container.
final class ProtectedFile<Value: Codable> {
    let url: URL
    let initial: () -> Value
    init(url: URL, initial: @escaping () -> Value) { self.url = url; self.initial = initial }
    func transaction<Result>(_ body: (inout Value) throws -> Result) throws -> Result {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let lockURL = url.appendingPathExtension("lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ParlaError.message("Local storage is unavailable.") }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw ParlaError.message("Could not coordinate local storage.") }
        var value: Value
        var previous: Data?
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url); previous = data
            value = try JSONDecoder().decode(Value.self, from: data)
        } else { value = initial() }
        let result = try body(&value)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard previous != data else { return result }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var protectedURL = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protectedURL.setResourceValues(values)
        return result
    }
}
enum SharedContainer {
    static var groupID: String { Bundle.main.object(forInfoDictionaryKey: "ParlaAppGroup") as? String ?? "group.dev.parla.ios" }
    static func file() throws -> ProtectedFile<SessionEnvelope> {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw ParlaError.message("App Group unavailable. Check signing and Full Access in Settings.")
        }
        return ProtectedFile(url: root.appendingPathComponent("session-v1.json"), initial: { SessionEnvelope() })
    }
}
