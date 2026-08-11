import Foundation

public struct CleanupSettings: Codable, Equatable, Sendable {
    public var provider: String = "anthropic"   // "anthropic" | "openai-compatible"
    public var baseURL: String? = nil            // required for openai-compatible
    // These three apply to openai-compatible only; anthropic uses the top-level
    // cleanupModel/anthropicApiKey fields.
    public var model: String? = nil              // nil ⇒ server's first model
    public var apiKeyEnvVar: String? = nil       // name of env var holding the key
    public var apiKey: String? = nil             // inline fallback
    public init() {}

    // Tolerant decode: a partial cleanup block must not throw and reset all Settings.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? provider
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? baseURL
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? model
        apiKeyEnvVar = try c.decodeIfPresent(String.self, forKey: .apiKeyEnvVar) ?? apiKeyEnvVar
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? apiKey
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public var dictionary: [String] = []
    public var snippets: [String: String] = [:]
    // Cleanup is a constrained rewrite, not a reasoning task: Haiku is far
    // cheaper per dictation and materially faster. Sonnet stays one Hub field away.
    public var cleanupModel: String = "claude-haiku-4-5"
    public var anthropicApiKey: String? = nil
    public var whisperModelPath: String? = nil
    public var cleanup: CleanupSettings = CleanupSettings()
    // Local-only dictation history (menu paste-last / Recent). Never leaves the
    // machine; secure-field dictations are never recorded regardless.
    public var historyEnabled: Bool = true
    // Keep the dictation pill floating as a small idle capsule at all times,
    // morphing into the full pill during dictation. Off ⇒ transient toast only.
    public var showHudAlways: Bool = true
    // Idle bar size preset: "small" | "medium" | "large". Unknown values fall
    // back to small at the HUD layer.
    public var hudIdleSize: String = "small"
    // Show the shadow stream's text in Parla's own pill while dictating. Off by
    // default: it costs a whisper pass every ~300 ms on every dictation, which
    // the gated shadow stream otherwise skips entirely. Preview only — the text
    // is never inserted and never stored.
    public var streamPreviewEnabled: Bool = false
    // Core Audio UID of the input device to record from. nil ⇒ system default.
    // A UID that no longer resolves (device unplugged) also falls back to default.
    public var inputDeviceUID: String? = nil
    // Rebindable shortcuts, stored as "ctrl+cmd+v". Defaults are what shipped
    // hard-coded, so an existing settings.json keeps behaving identically.
    public var hotkeys: HotkeyBindings = HotkeyBindings()
    // First-run flow. False here is the fresh-install value (no settings.json at
    // all); the decoder below reads a *missing* key as completed, so nobody who
    // already has a settings.json is ever sent through onboarding.
    public var onboardingCompleted: Bool = false
    public init() {}

    // Tolerant decode: missing keys fall back to defaults so adding fields
    // never resets a user's settings.json. Encoding stays synthesized.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dictionary = try c.decodeIfPresent([String].self, forKey: .dictionary) ?? dictionary
        snippets = try c.decodeIfPresent([String: String].self, forKey: .snippets) ?? snippets
        cleanupModel = try c.decodeIfPresent(String.self, forKey: .cleanupModel) ?? cleanupModel
        anthropicApiKey = try c.decodeIfPresent(String.self, forKey: .anthropicApiKey) ?? anthropicApiKey
        whisperModelPath = try c.decodeIfPresent(String.self, forKey: .whisperModelPath) ?? whisperModelPath
        cleanup = try c.decodeIfPresent(CleanupSettings.self, forKey: .cleanup) ?? cleanup
        historyEnabled = try c.decodeIfPresent(Bool.self, forKey: .historyEnabled) ?? historyEnabled
        showHudAlways = try c.decodeIfPresent(Bool.self, forKey: .showHudAlways) ?? showHudAlways
        hudIdleSize = try c.decodeIfPresent(String.self, forKey: .hudIdleSize) ?? hudIdleSize
        streamPreviewEnabled = try c.decodeIfPresent(Bool.self, forKey: .streamPreviewEnabled) ?? streamPreviewEnabled
        inputDeviceUID = try c.decodeIfPresent(String.self, forKey: .inputDeviceUID) ?? inputDeviceUID
        hotkeys = try c.decodeIfPresent(HotkeyBindings.self, forKey: .hotkeys) ?? hotkeys
        // Not `?? onboardingCompleted`: we only get here because a settings.json
        // exists, and an existing user must not be interrupted by a first-run flow.
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? true
    }
}

public final class SettingsStore {
    public let url: URL
    /// Set by load() when settings.json exists but failed to load. nil means
    /// either no file (fine, defaults) or the last load succeeded.
    public var lastError: String? { lock.withLock { _lastError } }
    private var _lastError: String?

    /// Identity of the file the cache was built from. Both fields, not just
    /// mtime: a rewrite inside the same second keeps the timestamp but almost
    /// always changes the length. Missing file is (nil, nil), which is a
    /// distinct value from any real file, so the file appearing invalidates.
    private struct Stamp: Equatable {
        let mtime: Date?
        let size: Int?
    }
    private var cached: (stamp: Stamp, settings: Settings, error: String?)?
    /// load() is called from the fn-down handler on main and from transform()
    /// off-main. Uncontended, and never from the audio thread.
    private let lock = NSLock()

    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parla/settings.json")
    }

    /// Decoded settings, re-read only when the file changed. This is on the
    /// fn-down keypress path, so the steady state is one stat() rather than a
    /// read plus a JSON decode.
    public func load() -> Settings {
        let stamp = currentStamp()
        return lock.withLock {
            if let c = cached, c.stamp == stamp {
                _lastError = c.error
                return c.settings
            }
            let (settings, error) = readFromDisk()
            _lastError = error
            cached = (stamp, settings, error)
            return settings
        }
    }

    private func currentStamp() -> Stamp {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return Stamp(mtime: attrs?[.modificationDate] as? Date, size: attrs?[.size] as? Int)
    }

    private func readFromDisk() -> (Settings, String?) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (Settings(), nil) // no file: fine, defaults
        }
        do {
            return (try JSONDecoder().decode(Settings.self, from: Data(contentsOf: url)), nil)
        } catch {
            return (Settings(), Self.hint(error))
        }
    }

    /// One-line, length-capped summary of a decode error — shown as a menu item
    /// title, so it must stay short even if DecodingError's description is huge.
    private static func hint(_ error: Error) -> String {
        let desc = String(describing: error)
        let line = desc.split(separator: "\n", maxSplits: 1).first ?? "unreadable settings.json"
        return String(line.prefix(200))
    }

    public func save(_ settings: Settings) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(settings).write(to: url, options: .atomic)
        // Don't trust the stamp to notice our own write — an atomic replace can
        // land in the same second at the same length as what it replaced.
        lock.withLock { cached = nil }
    }
}
