import Foundation
import CryptoKit
import Darwin

/// Only nonsecret inputs used by the explicit Scratchpad action. Never cached by stamp.
public struct ScratchpadDictionaryConfiguration {
    public let enabled: Bool
    public let words: [String]
    public let signature: Data

    public init(settings: Settings) {
        enabled = settings.scratchpadDictionaryAlternativesEnabled
        words = settings.dictionary
        var hash = SHA256()
        func add(_ value: String) {
            var length = UInt64(value.utf8.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
            // Avoid a second giant legacy-row payload just to sign configuration.
            var chunk = Data(); chunk.reserveCapacity(1_024)
            for byte in value.utf8 {
                chunk.append(byte)
                if chunk.count == 1_024 { hash.update(data: chunk); chunk.removeAll(keepingCapacity: true) }
            }
            if !chunk.isEmpty { hash.update(data: chunk) }
        }
        add(enabled ? "enabled" : "disabled")
        add("words"); add(String(settings.dictionary.count)); settings.dictionary.forEach(add)
        add("snippets"); add(String(settings.snippets.count))
        for key in settings.snippets.keys.sorted() { add(key); add(settings.snippets[key]!) }
        add("rules"); add(String(settings.replacements.count))
        for rule in settings.replacements { add(rule.source); add(rule.replacement) }
        signature = Data(hash.finalize())
    }
}

public struct ScratchpadPreferenceFailure: Error, LocalizedError {
    public init() {}
    public var errorDescription: String? { "Your dictionary changed or can’t be read. Try again." }
}

/// Narrow fakeable I/O seam. Reads must enforce regular-file and max+1 semantics.
public struct ScratchpadPreferenceIO {
    public static let maxBytes = 1_048_576
    public var read: (URL) throws -> Data?
    public var write: (Data, URL) throws -> Void
    public init(read: @escaping (URL) throws -> Data?, write: @escaping (Data, URL) throws -> Void) {
        self.read = read; self.write = write
    }
    public static let application = Self(read: { url in
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw ScratchpadPreferenceFailure()
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= maxBytes else { throw ScratchpadPreferenceFailure() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let bytes = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard bytes.count <= maxBytes else { throw ScratchpadPreferenceFailure() }
        return bytes
    }, write: { data, url in
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    })
}

public enum ScratchpadPreferenceJSON {
    public static func decode(_ bytes: Data?) throws -> Settings {
        guard let bytes else { return Settings() }
        guard bytes.count <= ScratchpadPreferenceIO.maxBytes else { throw ScratchpadPreferenceFailure() }
        // Strict decoding, deliberately no SettingsStore's partial-block recovery.
        return try JSONDecoder().decode(Settings.self, from: bytes)
    }
    public static func patch(_ bytes: Data?, enabled: Bool, expected: Bool) throws -> Data {
        let settings = try decode(bytes)
        guard settings.scratchpadDictionaryAlternativesEnabled == expected else { throw ScratchpadPreferenceFailure() }
        let seed = try bytes ?? JSONEncoder().encode(Settings())
        guard var object = try JSONSerialization.jsonObject(with: seed) as? [String: Any] else { throw ScratchpadPreferenceFailure() }
        object["scratchpadDictionaryAlternativesEnabled"] = enabled
        let output = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard output.count <= ScratchpadPreferenceIO.maxBytes else { throw ScratchpadPreferenceFailure() }
        return output
    }
}
