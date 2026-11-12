import Foundation
import Darwin

// Advisory OS lock covers the entire read/modify/atomic-write transaction across processes.
// No UserDefaults session cache, no split writers, and no API key in the shared container.
final class ProtectedFile<Value: Codable> {
    let url: URL
    let initial: () -> Value
    let maximumBytes: Int?
    /// Only the app may drop an oversized file (transient delivery state); extensions refuse it without loading it.
    let replacesOversized: Bool
    init(url: URL, maximumBytes: Int? = nil, replacesOversized: Bool = false, initial: @escaping () -> Value) {
        self.url = url; self.maximumBytes = maximumBytes; self.replacesOversized = replacesOversized; self.initial = initial
    }
    func transaction<Result>(_ body: (inout Value) throws -> Result) throws -> Result {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let lockURL = url.appendingPathExtension("lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ParlaError.message("Local storage is unavailable.") }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw ParlaError.message("Could not access saved data. Try again.") }
        var value: Value
        var previous: Data?
        if FileManager.default.fileExists(atPath: url.path) {
            let size = maximumBytes == nil ? nil : try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            if let maximumBytes, (size ?? .max) > maximumBytes {
                guard replacesOversized else { throw ParlaError.message("This text is too long for the keyboard. Open Parla and copy from the app.") }
                try FileManager.default.removeItem(at: url); value = initial()
            } else {
                let data = try Data(contentsOf: url); previous = data
                if let maximumBytes, data.count > maximumBytes { throw ParlaError.message("This text is too long for the keyboard. Open Parla and copy from the app.") }
                value = try JSONDecoder().decode(Value.self, from: data)
            }
        } else { value = initial() }
        let result = try body(&value)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        if let maximumBytes, data.count > maximumBytes { throw ParlaError.message("This dictation is too long for the keyboard. Open Parla and copy from the app.") }
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
            throw ParlaError.message("Parla and its keyboard could not connect. If you are using the keyboard, enable Allow Full Access in iPhone Settings → General → Keyboard → Keyboards → Parla, then reopen Parla.")
        }
        return ProtectedFile(url: root.appendingPathComponent("session-v1.json"), maximumBytes: SharedResult.maximumEnvelopeBytes,
                            replacesOversized: !Bundle.main.bundlePath.hasSuffix(".appex"), initial: { SessionEnvelope() })
    }
}
