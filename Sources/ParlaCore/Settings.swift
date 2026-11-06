import Foundation

public struct CleanupSettings: Codable, Equatable, Sendable {
    public var provider: String = "anthropic"   // also "apple-intelligence" (explicit opt-in)
    public var localSourceLocale: String? = nil
    public var baseURL: String? = nil            // required for openai-compatible
    // These three apply to openai-compatible only; anthropic uses the top-level
    // cleanupModel/anthropicApiKey fields.
    public var model: String? = nil              // nil ⇒ server's first model
    public var apiKeyEnvVar: String? = nil       // name of env var holding the key
    public var apiKey: String? = nil             // legacy decode/migration input only
    public init() {}

    // Tolerant decode: a partial cleanup block must not throw and reset all Settings.
    private enum CodingKeys: String, CodingKey {
        case provider, baseURL, model, apiKeyEnvVar, apiKey, localSourceLocale
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(localSourceLocale, forKey: .localSourceLocale)
        try c.encodeIfPresent(provider, forKey: .provider)
        try c.encodeIfPresent(baseURL, forKey: .baseURL)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(apiKeyEnvVar, forKey: .apiKeyEnvVar)
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        localSourceLocale = try c.decodeIfPresent(String.self, forKey: .localSourceLocale)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? provider
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? baseURL
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? model
        apiKeyEnvVar = try c.decodeIfPresent(String.self, forKey: .apiKeyEnvVar) ?? apiKeyEnvVar
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? apiKey
    }
}

public struct Settings: Codable, Equatable, Sendable {
    /// One-shot physical event metadata; excluded from Codable and stripped by Session.
    public var physicalSurroundingTextGrant: SurroundingTextGrant? = nil
    public var cleanupFailover: CleanupFailoverPolicy?
    public var guidedTemplates = GuidedTemplateDocument()
    public var outputMode: DictationOutputMode = .cleanup
    public var transformPresets: [TransformPreset] = []
    public var selectedPresetID: UUID? = nil
    public var profiles: [DictationProfile] = []
    public var cleanupEnabled = true
    public var cleanupStyle: ProfileStyle = .standard
    public var dictionary: [String] = []
    public var snippets: [String: String] = [:]
    public var replacements: [LiteralReplacement] = []
    // Cleanup is a constrained rewrite, not a reasoning task: Haiku is far
    // cheaper per dictation and materially faster. Sonnet stays one Hub field away.
    public var cleanupModel: String = "claude-haiku-4-5"
    public var anthropicApiKey: String? = nil
    public var recognitionEngine: RecognitionEngine = .whisper
    public var appleSpeechLocale: String? = nil
    public var parakeetModelID: String = ParakeetWire.model
    /// nil is unfiltered multilingual; this is a script filter, never language ID.
    public var parakeetLanguageFilter: String? = nil
    /// Frozen composition refusal, never persisted as a fallback engine.
    public var recognitionConfigurationInvalid = false
    public var whisperModelPath: String? = nil
    // Spoken language for a multilingual whisper model: nil ⇒ follow whatever
    // is spoken, a code ("en", "hi") ⇒ always that language. English-only
    // models ignore it.
    public var language: String? = nil
    public var cleanup: CleanupSettings = CleanupSettings()
    // Local-only dictation history (menu paste-last / Recent). Never leaves the
    // machine; secure-field dictations are never recorded regardless.
    /// One brief RAM original for explicit Copy; independent of history.
    public var scratchpadDictionaryAlternativesEnabled = false
    public var canceledCaptureUndoEnabled = false
    public var clipboardReceiptRestoreEnabled = false
    public var energyActivityShadowEnabled = false
    public var keepLastOriginalEnabled = true
    public var automationEnabled = false
    public var historyEnabled: Bool = true
    /// Independent of audio retention and enablement; zero is never “off”.
    public var historyTextCount: Int = HistoryStore.cap {
        didSet { historyTextCount = HistoryStore.boundedCount(historyTextCount) }
    }
    /// Independent audio controls; turning off prevents even corpus-mode stashes.
    public var recoveryAudioEnabled = true
    public var recoveryAudioDays = 7 {
        didSet { recoveryAudioDays = min(30, max(1, recoveryAudioDays)) }
    }
    // Keep the dictation pill floating as a small idle capsule at all times,
    // morphing into the full pill during dictation. Off ⇒ transient toast only.
    public var showHudAlways: Bool = true
    // Idle bar size preset: "small" | "medium" | "large". Unknown values fall
    // back to small at the HUD layer.
    public var hudIdleSize: String = "small"
    // Hold the mic open between dictations so one starts instantly and can
    // prepend the 0.45 s spoken before the key went down. Off by default because
    // the cost is macOS's orange mic indicator lit the whole time Parla runs —
    // docs/research/01-landscape.md:248 specified this default and it shipped
    // inverted. The benefit is real but has never been measured on Parla itself
    // (03-latency.md:17 marks the segment "not measured, not instrumented"), so
    // the user gets to price the indicator against a latency win we can't quote.
    public var nativePreparationSafeStartEnabled = false
    public var nativePreparationConsent: UUID?
    public var warmMic: Bool = false
    // Show the shadow stream's text in Parla's own pill while dictating. Off by
    // default: it costs a whisper pass every ~300 ms on every dictation, which
    // the gated shadow stream otherwise skips entirely. Preview only — the text
    // is never inserted and never stored.
    public var streamPreviewEnabled: Bool = false
    /// Explicit global experimental HUD model. Nil retains the ordinary shadow stream.
    public var recognitionPreviewModelID: String? = nil
    // Core Audio UID of the input device to record from. nil ⇒ system default.
    // A UID that no longer resolves (device unplugged) also falls back to default.
    public var inputDeviceUID: String? = nil
    // Rebindable shortcuts, stored as "ctrl+cmd+v". Defaults are what shipped
    // hard-coded, so an existing settings.json keeps behaving identically.
    public var hotkeys: HotkeyBindings = HotkeyBindings()
    /// Optional hold trigger, deliberately separate from canonical keyboard chords.
    public var mouseBinding: MouseButtonBinding? = nil {
        didSet { mouseBindingProblem = nil }
    }
    public private(set) var mouseBindingProblem: String? = nil
    // First-run flow. False here is the fresh-install value (no settings.json at
    // all); the decoder below reads a *missing* key as completed, so nobody who
    // already has a settings.json is ever sent through onboarding.
    public var onboardingCompleted: Bool = false
    public init() {}

    // Tolerant decode: missing keys fall back to defaults so adding fields
    // never resets a user's settings.json. Encoding explicitly excludes credentials.
    private enum CodingKeys: String, CodingKey {
        case cleanupFailover, guidedTemplates, energyActivityShadowEnabled, recognitionEngine, appleSpeechLocale, parakeetModelID, parakeetLanguageFilter, scratchpadDictionaryAlternativesEnabled, nativePreparationSafeStartEnabled, nativePreparationConsent, canceledCaptureUndoEnabled, clipboardReceiptRestoreEnabled, keepLastOriginalEnabled, automationEnabled, outputMode, transformPresets, selectedPresetID, profiles, cleanupEnabled, cleanupStyle, dictionary, snippets, replacements, cleanupModel, anthropicApiKey, whisperModelPath, language, cleanup, historyEnabled, historyTextCount, recoveryAudioEnabled, recoveryAudioDays, showHudAlways, hudIdleSize, warmMic, streamPreviewEnabled, recognitionPreviewModelID, inputDeviceUID, hotkeys, mouseBinding, onboardingCompleted
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try cleanupFailover?.validate()
        try c.encodeIfPresent(cleanupFailover, forKey: .cleanupFailover)
        try guidedTemplates.validate()
        try c.encode(guidedTemplates, forKey: .guidedTemplates)
        try c.encode(recognitionEngine, forKey: .recognitionEngine)
        try c.encode(parakeetModelID, forKey: .parakeetModelID)
        try c.encodeIfPresent(parakeetLanguageFilter, forKey: .parakeetLanguageFilter)
        try c.encodeIfPresent(appleSpeechLocale, forKey: .appleSpeechLocale)
        try c.encode(scratchpadDictionaryAlternativesEnabled, forKey: .scratchpadDictionaryAlternativesEnabled)
        try c.encode(nativePreparationSafeStartEnabled, forKey: .nativePreparationSafeStartEnabled)
        try c.encodeIfPresent(nativePreparationConsent, forKey: .nativePreparationConsent)
        try c.encode(canceledCaptureUndoEnabled, forKey: .canceledCaptureUndoEnabled)
        try c.encode(clipboardReceiptRestoreEnabled, forKey: .clipboardReceiptRestoreEnabled)
        try c.encode(energyActivityShadowEnabled, forKey: .energyActivityShadowEnabled)
        try c.encode(keepLastOriginalEnabled, forKey: .keepLastOriginalEnabled)
        try c.encode(automationEnabled, forKey: .automationEnabled)
        try c.encodeIfPresent(outputMode, forKey: .outputMode)
        try c.encodeIfPresent(transformPresets, forKey: .transformPresets)
        try c.encodeIfPresent(selectedPresetID, forKey: .selectedPresetID)
        try c.encodeIfPresent(profiles, forKey: .profiles)
        try c.encodeIfPresent(cleanupEnabled, forKey: .cleanupEnabled)
        try c.encodeIfPresent(cleanupStyle, forKey: .cleanupStyle)
        try c.encodeIfPresent(dictionary, forKey: .dictionary)
        try c.encodeIfPresent(snippets, forKey: .snippets)
        try c.encodeIfPresent(replacements, forKey: .replacements)
        try c.encodeIfPresent(cleanupModel, forKey: .cleanupModel)
        try c.encodeIfPresent(whisperModelPath, forKey: .whisperModelPath)
        try c.encodeIfPresent(language, forKey: .language)
        try c.encodeIfPresent(cleanup, forKey: .cleanup)
        try c.encodeIfPresent(historyEnabled, forKey: .historyEnabled)
        try c.encodeIfPresent(historyTextCount, forKey: .historyTextCount)
        try c.encodeIfPresent(recoveryAudioEnabled, forKey: .recoveryAudioEnabled)
        try c.encodeIfPresent(recoveryAudioDays, forKey: .recoveryAudioDays)
        try c.encodeIfPresent(showHudAlways, forKey: .showHudAlways)
        try c.encodeIfPresent(hudIdleSize, forKey: .hudIdleSize)
        try c.encodeIfPresent(warmMic, forKey: .warmMic)
        try c.encodeIfPresent(streamPreviewEnabled, forKey: .streamPreviewEnabled)
        try c.encodeIfPresent(recognitionPreviewModelID, forKey: .recognitionPreviewModelID)
        try c.encodeIfPresent(inputDeviceUID, forKey: .inputDeviceUID)
        try c.encodeIfPresent(hotkeys, forKey: .hotkeys)
        try c.encodeIfPresent(mouseBinding, forKey: .mouseBinding)
        try c.encodeIfPresent(onboardingCompleted, forKey: .onboardingCompleted)
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.cleanupFailover) {
            cleanupFailover = try c.decode(CleanupFailoverPolicy.self, forKey: .cleanupFailover)
            try cleanupFailover!.validate()
        }
        if c.contains(.guidedTemplates) { guidedTemplates = try c.decode(GuidedTemplateDocument.self, forKey: .guidedTemplates); try guidedTemplates.validate() }
        recognitionEngine = try c.decodeIfPresent(RecognitionEngine.self, forKey: .recognitionEngine) ?? .whisper
        if c.contains(.appleSpeechLocale), !(try c.decodeNil(forKey: .appleSpeechLocale)) {
            if let value = try? c.decode(String.self, forKey: .appleSpeechLocale), AppleSpeechLocale.isValid(value) { appleSpeechLocale = value }
            else { recognitionEngine = .invalid }
        }
        if c.contains(.parakeetModelID), !(try c.decodeNil(forKey: .parakeetModelID)) {
            if let value = try? c.decode(String.self, forKey: .parakeetModelID), value == ParakeetWire.model { parakeetModelID = value }
            else { recognitionEngine = .invalid }
        }
        if c.contains(.parakeetLanguageFilter), !(try c.decodeNil(forKey: .parakeetLanguageFilter)) {
            if let value = try? c.decode(String.self, forKey: .parakeetLanguageFilter), ParakeetWire.filters.contains(value) { parakeetLanguageFilter = value }
            else { recognitionEngine = .invalid }
        }
        scratchpadDictionaryAlternativesEnabled = try c.decodeIfPresent(Bool.self, forKey: .scratchpadDictionaryAlternativesEnabled) ?? false
        nativePreparationSafeStartEnabled = try c.decodeIfPresent(Bool.self, forKey: .nativePreparationSafeStartEnabled) ?? false
        nativePreparationConsent = try c.decodeIfPresent(UUID.self, forKey: .nativePreparationConsent)
        canceledCaptureUndoEnabled = try c.decodeIfPresent(Bool.self, forKey: .canceledCaptureUndoEnabled) ?? false
        clipboardReceiptRestoreEnabled = try c.decodeIfPresent(Bool.self, forKey: .clipboardReceiptRestoreEnabled) ?? false
        energyActivityShadowEnabled = try c.decodeIfPresent(Bool.self, forKey: .energyActivityShadowEnabled) ?? false
        keepLastOriginalEnabled = try c.decodeIfPresent(Bool.self, forKey: .keepLastOriginalEnabled) ?? true
        automationEnabled = try c.decodeIfPresent(Bool.self, forKey: .automationEnabled) ?? false
        outputMode = try c.decodeIfPresent(DictationOutputMode.self, forKey: .outputMode) ?? .cleanup
        transformPresets = try c.decodeIfPresent([TransformPreset].self, forKey: .transformPresets) ?? []
        selectedPresetID = try c.decodeIfPresent(UUID.self, forKey: .selectedPresetID)
        profiles = try c.decodeIfPresent([DictationProfile].self, forKey: .profiles) ?? []
        cleanupEnabled = try c.decodeIfPresent(Bool.self, forKey: .cleanupEnabled) ?? true
        cleanupStyle = try c.decodeIfPresent(ProfileStyle.self, forKey: .cleanupStyle) ?? .standard
        dictionary = try c.decodeIfPresent([String].self, forKey: .dictionary) ?? dictionary
        snippets = try c.decodeIfPresent([String: String].self, forKey: .snippets) ?? snippets
        replacements = try c.decodeIfPresent([LiteralReplacement].self, forKey: .replacements) ?? replacements
        cleanupModel = try c.decodeIfPresent(String.self, forKey: .cleanupModel) ?? cleanupModel
        anthropicApiKey = try c.decodeIfPresent(String.self, forKey: .anthropicApiKey) ?? anthropicApiKey
        whisperModelPath = try c.decodeIfPresent(String.self, forKey: .whisperModelPath) ?? whisperModelPath
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? language
        cleanup = try c.decodeIfPresent(CleanupSettings.self, forKey: .cleanup) ?? cleanup
        historyEnabled = try c.decodeIfPresent(Bool.self, forKey: .historyEnabled) ?? historyEnabled
        historyTextCount = HistoryStore.boundedCount(try c.decodeIfPresent(Int.self, forKey: .historyTextCount) ?? HistoryStore.cap)
        recoveryAudioEnabled = try c.decodeIfPresent(Bool.self, forKey: .recoveryAudioEnabled) ?? true
        let days = try c.decodeIfPresent(Int.self, forKey: .recoveryAudioDays) ?? 7
        guard RecordingStore.dayRange.contains(days) else {
            throw DecodingError.dataCorruptedError(forKey: .recoveryAudioDays, in: c, debugDescription: "Audio lifetime must be 1–30 days.")
        }
        recoveryAudioDays = days
        showHudAlways = try c.decodeIfPresent(Bool.self, forKey: .showHudAlways) ?? showHudAlways
        hudIdleSize = try c.decodeIfPresent(String.self, forKey: .hudIdleSize) ?? hudIdleSize
        warmMic = try c.decodeIfPresent(Bool.self, forKey: .warmMic) ?? warmMic
        streamPreviewEnabled = try c.decodeIfPresent(Bool.self, forKey: .streamPreviewEnabled) ?? streamPreviewEnabled
        recognitionPreviewModelID = try c.decodeIfPresent(String.self, forKey: .recognitionPreviewModelID)
        inputDeviceUID = try c.decodeIfPresent(String.self, forKey: .inputDeviceUID) ?? inputDeviceUID
        hotkeys = try c.decodeIfPresent(HotkeyBindings.self, forKey: .hotkeys) ?? hotkeys
        do { mouseBinding = try c.decodeIfPresent(MouseButtonBinding.self, forKey: .mouseBinding) }
        catch { mouseBinding = nil; mouseBindingProblem = "Mouse trigger disabled: choose Middle or an extra button from 4 to 16." }
        // Not `?? onboardingCompleted`: we only get here because a settings.json
        // exists, and an existing user must not be interrupted by a first-run flow.
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? true
    }
}

public final class SettingsStore {
    public let url: URL
    public let credentials: CredentialStore
    public static let configurationDidChange = Notification.Name("Parla.Settings.configurationDidChange")
    public static let scratchpadPreferenceDidChange = Notification.Name("Parla.Settings.scratchpadPreferenceDidChange")
    private let scratchpadIO: ScratchpadPreferenceIO
    /// Optional in-memory document bottom for connected model-free consumers.
    public struct DocumentIO {
        public var read: () throws -> Data?
        public var prepareParent: () throws -> Void
        public init(read: @escaping () throws -> Data?, prepareParent: @escaping () throws -> Void = {}) {
            self.read = read; self.prepareParent = prepareParent
        }
    }
    private let documentIO: DocumentIO?
    private let atomicWrite: (Data, URL) throws -> Void
    public var migrationError: String? { lock.withLock { _migrationError } }
    private var _migrationError: String?
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
        let readError: Int?
    }
    private var cached: (stamp: Stamp, settings: Settings, error: String?)?
    /// load() is called from the fn-down handler on main and from transform()
    /// off-main. Uncontended, and never from the audio thread.
    private let lock = NSRecursiveLock()
    private var contextEpoch: UInt64 = 1
    private var contextPaused = false
    private var contextObserved: Data?
    private var contextCancellations: [UUID: () -> Void] = [:]
    private var failoverEpoch: UInt64 = 1
    private var failoverPaused = false
    private var failoverObserved: Data?
    private var failoverCancellations: [UUID: () -> Void] = [:]

    public init(url: URL? = nil, credentials: CredentialStore = .shared,
                scratchpadIO: ScratchpadPreferenceIO = .application, documentIO: DocumentIO? = nil,
                atomicWrite: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.documentIO = documentIO
        self.credentials = credentials
        self.scratchpadIO = scratchpadIO
        self.atomicWrite = atomicWrite
        self.url = url ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parla/settings.json")
    }

    /// Decoded settings, re-read only when the file changed. This is on the
    /// fn-down keypress path, so the steady state is one stat() rather than a
    /// read plus a JSON decode.
    public func load() -> Settings {
        let stamp = documentIO == nil ? currentStamp() : Stamp(mtime: nil, size: nil, readError: nil)
        return lock.withLock {
            if documentIO == nil, let c = cached, c.stamp == stamp {
                _lastError = c.error
                return c.settings
            }
            let (settings, error) = readFromDisk()
            _lastError = error
            cached = (stamp, settings, error)
            return settings
        }
    }

    /// Explicit saved-Original experiments require a real, fully decodable file.
    /// This read neither migrates credentials nor updates/repairs the cached defaults.
    public enum SavedSnapshotFailure: Error { case missing, unreadable, corrupt }
    public func savedRetrySnapshot() throws -> Settings {
        try lock.withLock {
            do { let value = try decodeSavedSnapshot(); observeFailoverLocked(value); return value }
            catch { revokeSurroundingTextLocked(); revokeFailoverLocked(); throw error }
        }
    }
    private func decodeSavedSnapshot() throws -> Settings {
        if let documentIO {
            guard let data = try optionalSettingsBytes() else { throw SavedSnapshotFailure.missing }
            return try JSONDecoder().decode(Settings.self, from: data)
        }
        do { _ = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            throw SavedSnapshotFailure.missing
        } catch { throw SavedSnapshotFailure.unreadable }
        let data: Data
        do { data = try readSettingsBytes() }
        catch { throw SavedSnapshotFailure.unreadable }
        do { return try JSONDecoder().decode(Settings.self, from: data) }
        catch { throw SavedSnapshotFailure.corrupt }
    }

    private func currentStamp() -> Stamp {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            return Stamp(mtime: attrs[.modificationDate] as? Date, size: attrs[.size] as? Int, readError: nil)
        } catch { return Stamp(mtime: nil, size: nil, readError: (error as NSError).code) }
    }

    private func readSettingsBytes() throws -> Data {
        do {
            let bytes: Data
            if let documentIO {
                guard let value = try documentIO.read() else { throw CocoaError(.fileReadNoSuchFile) }
                bytes = value
            } else { bytes = try Data(contentsOf: url) }
            observeFailoverBytesLocked(bytes)
            return bytes
        } catch { revokeSurroundingTextLocked(); revokeFailoverLocked(); throw error }
    }
    private func settingsExist() throws -> Bool {
        if documentIO != nil { return try optionalSettingsBytes() != nil }
        return FileManager.default.fileExists(atPath: url.path)
    }
    private func prepareSettingsParent() throws {
        if let documentIO { try documentIO.prepareParent() }
        else { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
    }

    private func readFromDisk() -> (Settings, String?) {
        let value = decodeFromDisk()
        if value.1 != nil { revokeSurroundingTextLocked() }
        if value.1 == nil { observeFailoverLocked(value.0) } else { revokeFailoverLocked() }
        return value
    }
    private func decodeFromDisk() -> (Settings, String?) {
        // Existence probes collapse permission/read errors into "missing".
        // Only a positively missing leaf authorizes defaults; a dangling alias
        // or unreadable settings must not authorize recovery retention/pruning.
        do { if documentIO == nil { _ = try FileManager.default.attributesOfItem(atPath: url.path) } else if try !settingsExist() { observeSurroundingTextBytesLocked(nil); return (Settings(), nil) } }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            observeSurroundingTextBytesLocked(nil)
            return (Settings(), nil)
        } catch { revokeSurroundingTextLocked(); return (Settings(), Self.hint(error)) }
        do {
            let data = try readSettingsBytes()
            do {
                return (try JSONDecoder().decode(Settings.self, from: data), nil)
            } catch {
                // Remove only an independently malformed B21 block in memory.
                // Then retain the existing single-block recovery semantics for the
                // remainder, including explicit profile refusal. Never rewrite bytes.
                if var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let block = object["cleanupFailover"],
                   (try? Self.decodeFailoverBlock(block)) == nil {
                    object.removeValue(forKey: "cleanupFailover")
                    let remainder = try JSONSerialization.data(withJSONObject: object)
                    if let globals = try? JSONDecoder().decode(Settings.self, from: remainder) {
                        return (globals, "Cleanup backups rejected; editing disabled. " + Self.hint(error))
                    }
                    for key in ["guidedTemplates", "profiles", "transformPresets"] where object[key] != nil {
                        var candidate = object; candidate.removeValue(forKey: key)
                        if var globals = try? JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: candidate)) {
                            if key == "profiles" { globals.recognitionEngine = .invalid }
                            return (globals, "Cleanup backups and related block rejected; editing disabled. " + Self.hint(error))
                        }
                    }
                }
                // Template-only corruption preserves unrelated decodable global intent.
                // Strict snapshot/edit/full-write APIs still reject the original bytes.
                if var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   object.removeValue(forKey: "guidedTemplates") != nil,
                   let globals = try? JSONDecoder().decode(Settings.self,
                       from: JSONSerialization.data(withJSONObject: object)) {
                    return (globals, "Templates rejected; editing disabled. " + Self.hint(error))
                }
                // Reject the entire new profile block, keep unrelated globals usable,
                // and leave the original bytes untouched. lastError disables Hub saves
                // and vocabulary imports until the user repairs the file.
                if var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   object.removeValue(forKey: "profiles") != nil,
                   let globals = try? JSONDecoder().decode(Settings.self,
                       from: JSONSerialization.data(withJSONObject: object)) {
                    var refused = globals; refused.recognitionEngine = .invalid
                    return (refused, "Profiles rejected; editing disabled. " + Self.hint(error))
                }
                if var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   object.removeValue(forKey: "transformPresets") != nil,
                   let globals = try? JSONDecoder().decode(Settings.self,
                       from: JSONSerialization.data(withJSONObject: object)) {
                    return (globals, "Presets rejected; editing disabled. " + Self.hint(error))
                }
                return (Self.refusedExplicitRecognition(in: data), Self.hint(error))
            }
        } catch {
            return (Settings(), Self.hint(error))
        }
    }

    private static func refusedExplicitRecognition(in data: Data) -> Settings {
        var value = Settings()
        // Keep unrelated legacy corrupt-file fallback. Explicit engine/locale intent may
        // never disappear when another malformed block prevents a complete decode.
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           ["recognitionEngine", "appleSpeechLocale", "parakeetModelID", "parakeetLanguageFilter"].contains(where: { object[$0] != nil && !(object[$0] is NSNull) }) {
            value.recognitionEngine = .invalid
        }
        return value
    }

    /// One-line, length-capped summary of a decode error — shown as a menu item
    /// title, so it must stay short even if DecodingError's description is huge.
    private static func hint(_ error: Error) -> String {
        let desc = String(describing: error)
        let line = desc.split(separator: "\n", maxSplits: 1).first ?? "unreadable settings.json"
        return String(line.prefix(200))
    }

    /// Fresh, bounded and credential-free; no recovered/cache value authorizes an edit.
    public func scratchpadDictionaryConfiguration() throws -> ScratchpadDictionaryConfiguration {
        try lock.withLock {
            ScratchpadDictionaryConfiguration(settings: try ScratchpadPreferenceJSON.decode(readFailoverObservedNarrowLocked()))
        }
    }

    @discardableResult
    public func setScratchpadDictionaryAlternativesEnabled(_ enabled: Bool, expected: Bool) throws -> Bool {
        try lock.withLock {
            let original = try readFailoverObservedNarrowLocked()
            observeFailoverLocked(try ScratchpadPreferenceJSON.decode(original))
            let output = try ScratchpadPreferenceJSON.patch(original, enabled: enabled, expected: expected)
            guard try readFailoverObservedNarrowLocked() == original else { throw ScratchpadPreferenceFailure() }
            try scratchpadIO.write(output, url)
            cached = nil
        }
        // Reentrant observers may load settings: always after unlocking, no content payload.
        NotificationCenter.default.post(name: Self.scratchpadPreferenceDidChange, object: self,
                                        userInfo: ["enabled": enabled])
        NotificationCenter.default.post(name: Self.configurationDidChange, object: self)
        return enabled
    }

    /// Returns the dedicated preference actually preserved by this full save.
    @discardableResult
    public func save(_ settings: Settings, replacing base: Settings? = nil) throws -> Bool {
        try savePreservingTemplates(settings, replacing: base).scratchpadDictionaryAlternativesEnabled
    }

    public func savePreservingTemplates(_ settings: Settings, replacing base: Settings? = nil) throws -> Settings {
        let committed = try lock.withLock {
            // All existing full writers (Hub/model installer/status menu) preserve this
            // dedicated preference. Do not refresh any other stale draft/base fields.
            let (current, error) = readFromDisk()
            guard error == nil else { throw ScratchpadPreferenceFailure() }
            // Migration and legacy verification may call credential bottoms.
            // Re-read exact authority after that interval, never reuse the draft.
            if !settings.usesAppleIntelligence { try migrateLocked(); try rejectNewInline(settings) }
            let original = try optionalSettingsBytes()
            let fresh = try original.map { try JSONDecoder().decode(Settings.self, from: $0) } ?? current
            var settings = try preservingFailover(settings, current: fresh, base: base)
            settings.guidedTemplates = fresh.guidedTemplates
            settings.scratchpadDictionaryAlternativesEnabled = fresh.scratchpadDictionaryAlternativesEnabled
            var base = base
            base?.guidedTemplates = fresh.guidedTemplates
            base?.scratchpadDictionaryAlternativesEnabled = fresh.scratchpadDictionaryAlternativesEnabled
            base?.cleanupFailover = fresh.cleanupFailover
            guard try optionalSettingsBytes() == original else { throw CleanupFailoverFailure.changed }
            if settings.usesAppleIntelligence { try writeLocalPreserving(settings, replacing: base) }
            else { try write(settings, expectedOriginal: original, contextBase: base) }
            observeFailoverLocked(settings)
            cached = nil
            return settings
        }
        NotificationCenter.default.post(name: Self.configurationDidChange, object: self)
        return committed
    }


    /// Narrow CRUD uses bounded nofollow I/O only; ordinary full saves retain their legacy size policy.
    public func templateDocument() throws -> GuidedTemplateDocument {
        try lock.withLock { try ScratchpadPreferenceJSON.decode(readFailoverObservedNarrowLocked()).guidedTemplates }
    }

    @discardableResult
    public func saveTemplateDefinition(_ candidate: GuidedTemplateDefinition, expectedRevision: UUID?) throws -> GuidedTemplateDocument {
        try mutateTemplates { document in
            _ = try candidate.compiled()
            var candidate = candidate
            if let index = document.definitions.firstIndex(where: { $0.id == candidate.id }) {
                guard expectedRevision == document.definitions[index].revision else { throw GuidedTemplateFailure("Template changed. Reopen the editor.") }
                candidate.revision = UUID(); document.definitions[index] = candidate
            } else {
                guard expectedRevision == nil else { throw GuidedTemplateFailure("Template was deleted. Reopen the editor.") }
                candidate.revision = UUID(); document.definitions.append(candidate)
            }
        }
    }

    @discardableResult
    public func deleteTemplateDefinition(_ id: UUID, expectedRevision: UUID) throws -> GuidedTemplateDocument {
        try mutateTemplates { document in
            guard let index = document.definitions.firstIndex(where: { $0.id == id }), document.definitions[index].revision == expectedRevision else {
                throw GuidedTemplateFailure("Template changed or was deleted.")
            }
            document.definitions.remove(at: index)
        }
    }

    private func mutateTemplates(_ mutation: (inout GuidedTemplateDocument) throws -> Void) throws -> GuidedTemplateDocument {
        let committed = try lock.withLock {
            let original = try readFailoverObservedNarrowLocked()
            let settings = try ScratchpadPreferenceJSON.decode(original)
            observeFailoverLocked(settings)
            var document = settings.guidedTemplates
            try mutation(&document); try document.validate()
            let seed = try original ?? JSONEncoder().encode(Settings())
            guard var object = try JSONSerialization.jsonObject(with: seed) as? [String: Any] else { throw GuidedTemplateFailure("Settings unavailable.") }
            object["guidedTemplates"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(document))
            let output = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            guard output.count <= ScratchpadPreferenceIO.maxBytes else { throw GuidedTemplateFailure("Settings exceed narrow template editing limit.") }
            _ = try JSONDecoder().decode(Settings.self, from: output)
            guard try readFailoverObservedNarrowLocked() == original else { throw GuidedTemplateFailure("Settings changed during template edit.") }
            try scratchpadIO.write(output, url); cached = nil
            return document
        }
        NotificationCenter.default.post(name: Self.configurationDidChange, object: self)
        return committed
    }

    /// Re-read under the write lock: a preview can never replace newer vocabulary.
    /// Unrelated settings are taken from disk at application time, not the preview.
    @discardableResult
    public func importVocabulary(_ preview: VocabularyImportPreview, mode: VocabularyImportMode,
                                 backupDirectory: URL? = nil) throws -> URL? {
        let backup = try lock.withLock {
            let (selected, selectedError) = readFromDisk()
            _lastError = selectedError
            if selectedError != nil { cached = nil }
            guard selectedError == nil else { throw CredentialFailure("Settings unavailable. Reload before importing.") }
            if !selected.usesAppleIntelligence { try migrateLocked() }
            let (current, error) = readFromDisk()
            _lastError = error
            cached = nil
            guard error == nil else { throw VocabularyTransferError.invalid("Cannot import: settings failed to load.") }
            guard VocabularyDocument(settings: current) == preview.original else {
                throw VocabularyTransferError.invalid("Vocabulary changed since preview. Open the import again.")
            }
            let document = preview.result(mode: mode)
            guard mode != .replace || !document.isEmpty else {
                throw VocabularyTransferError.invalid("Empty replacement imports are refused. Use the editors to clear vocabulary.")
            }
            _ = try document.encoded()
            var backup: URL?
            if mode == .replace {
                let directory = backupDirectory ?? url.deletingLastPathComponent().appendingPathComponent("vocabulary-backups")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let target = directory.appendingPathComponent("vocabulary-\(UUID().uuidString).json")
                try preview.original.encoded().write(to: target, options: .atomic)
                backup = target
            }
            let original = try optionalSettingsBytes()
            guard try original.map({ try JSONDecoder().decode(Settings.self, from: $0) }) == current else { throw CleanupFailoverFailure.changed }
            let updated = document.applying(to: current)
            if current.usesAppleIntelligence { try writeLocalPreserving(updated, replacing: current) }
            else { try write(updated, expectedOriginal: original, contextBase: current) }
            cached = nil
            return backup
        }
        NotificationCenter.default.post(name: Self.configurationDidChange, object: self)
        return backup
    }

    /// Explicit lifecycle/save boundary; never called by load(), a property or rendering.
    @discardableResult public func migrateCredentials() -> String? {
        lock.withLock {
            do { try migrateLocked(); return nil }
            catch { return _migrationError ?? "Credential migration pending. Original settings preserved." }
        }
    }

    /// Automatic entry defers inactive network credentials for the local provider.
    @discardableResult public func migrateSelectedCredentials() -> String? {
        lock.withLock {
            let (settings, error) = readFromDisk()
            guard error == nil else { return "Settings unavailable. Repair and reload." }
            if settings.usesAppleIntelligence { return nil }
            do { try migrateLocked(); return nil }
            catch { return _migrationError ?? "Credential migration pending." }
        }
    }

    /// Only this disk writer can preserve legacy secrets. General encoding stays
    /// secret-free. Never consult credentials to authorize a local edit.
    private func writeLocalPreserving(_ settings: Settings, replacing base: Settings?) throws {
        let (current, error) = readFromDisk()
        guard error == nil else { throw CredentialFailure("Settings unavailable. Reload before saving.") }
        let original: Data?
        do { original = try readSettingsBytes() }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { original = nil }
        let authoritative = try original.map { try JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        guard authoritative == current,
              base.map({ $0 == authoritative }) ?? (cached.map({ cached in var value = cached.settings; value.guidedTemplates = authoritative.guidedTemplates; value.cleanupFailover = authoritative.cleanupFailover; value.scratchpadDictionaryAlternativesEnabled = authoritative.scratchpadDictionaryAlternativesEnabled; return cached.error == nil && value == authoritative }) ?? true),
              settings.anthropicApiKey == authoritative.anthropicApiKey,
              settings.cleanup.apiKey == authoritative.cleanup.apiKey,
              settings.cleanup.baseURL == authoritative.cleanup.baseURL else {
            throw CredentialFailure("Settings or network credential binding changed. Reload before saving; original preserved.")
        }
        if settings == authoritative { return }
        let encoder = JSONEncoder()
        var object = try JSONSerialization.jsonObject(with: encoder.encode(settings)) as! [String: Any]
        if let original, let old = try JSONSerialization.jsonObject(with: original) as? [String: Any] {
            object["anthropicApiKey"] = old["anthropicApiKey"]
            if let legacy = old["cleanup"] as? [String: Any], let key = legacy["apiKey"] {
                var cleanup = object["cleanup"] as? [String: Any] ?? [:]
                cleanup["apiKey"] = key; object["cleanup"] = cleanup
            }
            guard try readSettingsBytes() == original else { throw CredentialFailure("Settings changed. Reload before saving.") }
        } else {
            guard !(try settingsExist()) else { throw CredentialFailure("Settings changed. Reload before saving.") }
        }
        try prepareSettingsParent()
        let encoded = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let output = try SurroundingTextAuthority.preserving(original, in: encoded, base: base, incoming: settings)
        guard try optionalSettingsBytes() == original else { throw SurroundingTextFailure.refused }
        try atomicWrite(output, url)
        observeSurroundingTextBytesLocked(output)
    }

    private func migrateLocked() throws {
        do {
            let (settings, error) = readFromDisk()
            _lastError = error
            if error != nil { cached = nil }
            guard error == nil else { throw CredentialFailure("Settings unavailable or invalid. Repair and reload before saving.") }
            guard (try settingsExist()) else { _migrationError = nil; return }
            let original = try readSettingsBytes()
            // Decode the exact bytes we compare, without the partial-block recovery path.
            let authoritative = try JSONDecoder().decode(Settings.self, from: original)
            guard authoritative == settings else { throw CredentialFailure("Settings changed. Reload before retrying migration.") }
            guard var object = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                throw CredentialFailure("Settings unavailable. Repair and reload before saving.")
            }
            let cleanup = object["cleanup"] as? [String: Any]
            guard object["anthropicApiKey"] != nil || cleanup?["apiKey"] != nil else { _migrationError = nil; return }
            if let key = authoritative.anthropicApiKey, !key.isEmpty { try credentials.migrate(key, scope: .anthropic) }
            if let key = authoritative.cleanup.apiKey, !key.isEmpty {
                try credentials.migrate(key, scope: CredentialScope.compatible(authoritative.cleanup.baseURL))
            }
            // An editor/provider switch during Keychain I/O must survive. Compare under
            // the same store lock immediately before the atomic legacy-field removal.
            guard try readSettingsBytes() == original else {
                throw CredentialFailure("Settings changed during migration. Reload and retry; newer settings preserved.")
            }
            object.removeValue(forKey: "anthropicApiKey")
            if var cleanup { cleanup.removeValue(forKey: "apiKey"); object["cleanup"] = cleanup }
            let written = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try atomicWrite(written, url); observeSurroundingTextBytesLocked(written)
            cached = nil; _migrationError = nil
        } catch {
            let message = (error as? CredentialFailure)?.description ?? "Credential migration pending. Original settings preserved; retry migration."
            _migrationError = message
            throw CredentialFailure(message)
        }
    }

    /// Explicit user mutation also resolves a matching legacy source. Other scopes
    /// and newer external bytes are retained. Failed disk writes remain retryable.
    public func changeCredential(scope: CredentialScope, replacement: String?) throws {
        try lock.withLock {
            let (_, error) = readFromDisk()
            guard error == nil else { throw CredentialFailure("Repair and reload settings before changing credentials.") }
            let original: Data?
            do { original = try readSettingsBytes() }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { original = nil }
            catch { throw CredentialFailure("Settings became unreadable. Reload before changing credentials.") }
            let settings = try original.map { try JSONDecoder().decode(Settings.self, from: $0) }
            if let replacement {
                guard !replacement.isEmpty else { return }
                try credentials.replace(replacement, scope: scope)
            } else { try credentials.remove(scope) }
            guard let original, let settings else { return }
            guard try readSettingsBytes() == original else {
                throw CredentialFailure("Settings changed during credential action. Reload and retry; newer settings preserved.")
            }
            var object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
            if scope == .anthropic { object.removeValue(forKey: "anthropicApiKey") }
            else if (try? CredentialScope.compatible(settings.cleanup.baseURL)) == scope,
                    var cleanup = object["cleanup"] as? [String: Any] {
                cleanup.removeValue(forKey: "apiKey"); object["cleanup"] = cleanup
            }
            let written = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try atomicWrite(written, url); observeSurroundingTextBytesLocked(written)
            cached = nil
        }
    }

    // B21 authority is independent of ordinary draft persistence and the queue's
    // abort slot. All synchronous checks and initiation share this recursive lock;
    // no await occurs under it. External editors are detected by fresh reads/CAS,
    // not claimed to participate in an OS-wide transaction.
    private func readFailoverObservedNarrowLocked() throws -> Data? {
        do {
            let bytes = try scratchpadIO.read(url)
            observeSurroundingTextBytesLocked(bytes)
            observeFailoverLocked(try ScratchpadPreferenceJSON.decode(bytes))
            return bytes
        } catch { revokeSurroundingTextLocked(); revokeFailoverLocked(); throw error }
    }
    private static func decodeFailoverBlock(_ object: Any) throws -> CleanupFailoverPolicy {
        let value = try JSONDecoder().decode(CleanupFailoverPolicy.self, from: JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]))
        try value.validate(); return value
    }
    private func optionalSettingsBytes() throws -> Data? {
        if let documentIO {
            do {
                let bytes = try documentIO.read()
                observeFailoverBytesLocked(bytes)
                return bytes
            } catch { revokeSurroundingTextLocked(); revokeFailoverLocked(); throw error }
        }
        do { return try readSettingsBytes() }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return nil }
    }
    // CAS/refusal reads also witness authority. Return the exact bytes unchanged
    // so existing decoding, scoped recovery and conflict errors keep their behavior.
    private func observeFailoverBytesLocked(_ bytes: Data?) {
        observeSurroundingTextBytesLocked(bytes)
        guard let bytes, let settings = try? JSONDecoder().decode(Settings.self, from: bytes) else {
            revokeFailoverLocked(); return
        }
        observeFailoverLocked(settings)
    }
    private static func primaryKey(_ settings: Settings) -> [String?] {
        let compatible = settings.cleanup.provider == "openai-compatible"
        return [settings.cleanup.provider.isEmpty ? "anthropic" : settings.cleanup.provider,
                (try? CredentialScope.selected(settings).baseURL) ?? settings.cleanup.baseURL,
                compatible ? settings.cleanup.model?.trimmingCharacters(in: .whitespacesAndNewlines) : settings.cleanupModel,
                compatible ? settings.cleanup.apiKeyEnvVar : "ANTHROPIC_API_KEY"]
    }
    private func authoritySignature(_ settings: Settings) -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try! encoder.encode(Self.primaryKey(settings))) + (try! encoder.encode(settings.cleanupFailover))
            + (try! encoder.encode(settings.profiles)) + (try! encoder.encode([settings.cleanupEnabled, settings.outputMode == .cleanup]))
    }
    private func revokeFailoverLocked() {
        precondition(failoverEpoch < UInt64.max)
        failoverEpoch += 1; failoverPaused = true
        let actions = Array(failoverCancellations.values); failoverCancellations.removeAll()
        actions.forEach { $0() }
    }
    private func observeFailoverLocked(_ settings: Settings) {
        let signature = authoritySignature(settings)
        if let previous = failoverObserved, previous != signature { revokeFailoverLocked() }
        failoverObserved = signature
    }
    public func revokeCleanupFailover() { lock.withLock { revokeFailoverLocked() } }
    public func observeCleanupFailoverDraft(from old: Settings, to new: Settings) {
        if Self.primaryKey(old) != Self.primaryKey(new) || old.profiles != new.profiles
            || old.cleanupEnabled != new.cleanupEnabled || old.outputMode != new.outputMode
            || old.cleanupFailover != new.cleanupFailover { revokeCleanupFailover() }
    }
    private func strictFailoverLocked(narrow: Bool = false) throws -> (Data, Settings) {
        do {
            let bytes: Data?
            if narrow, documentIO == nil { bytes = try readFailoverObservedNarrowLocked() }
            else { bytes = try optionalSettingsBytes() }
            guard let bytes, !narrow || bytes.count <= ScratchpadPreferenceIO.maxBytes else { throw CleanupFailoverFailure.configuration }
            let settings = try JSONDecoder().decode(Settings.self, from: bytes)
            observeFailoverLocked(settings)
            return (bytes, settings)
        } catch { revokeSurroundingTextLocked(); revokeFailoverLocked(); throw error }
    }
    private func preservingFailover(_ incoming: Settings, current: Settings, base: Settings?) throws -> Settings {
        var result = incoming; result.cleanupFailover = current.cleanupFailover
        if current.cleanupFailover != nil, Self.primaryKey(incoming) != Self.primaryKey(current) {
            guard let base, Self.primaryKey(base) == Self.primaryKey(current) else { throw CleanupFailoverFailure.changed }
            result.cleanupFailover?.review = nil
        }
        return result
    }
    /// Capture occurs before queue/ASR; binding to the fresh operation id is one-way.
    public func captureCleanupFailoverGrant(settings: Settings, origin: CleanupFailoverOrigin) -> CleanupFailoverGrant? {
        lock.withLock {
            guard let (_, current) = try? strictFailoverLocked(), !failoverPaused,
                  current.outputMode == .cleanup, current.cleanupEnabled, settings.outputMode == .cleanup, settings.cleanupEnabled,
                  let policy = current.cleanupFailover, policy == settings.cleanupFailover,
                  policy.isReviewed(for: settings), policy.isReviewed(for: current), let review = policy.review else { return nil }
            return CleanupFailoverGrant(epoch: failoverEpoch, revision: review.revision, digest: review.digest)
        }
    }
    public func withCleanupFailoverGrant(_ grant: CleanupFailoverGrant, operationID: UUID, _ action: () throws -> Void) throws {
        try lock.withLock {
            let (_, current) = try strictFailoverLocked()
            guard !failoverPaused, grant.operationID == operationID, grant.epoch == failoverEpoch,
                  let policy = current.cleanupFailover, policy.isReviewed(for: current), let review = policy.review,
                  grant.revision == review.revision, grant.digest == review.digest else { throw CleanupFailoverFailure.revoked }
            try action()
        }
    }
    public func registerCleanupFailoverCancellation(_ grant: CleanupFailoverGrant, operationID: UUID, cancel: @escaping () -> Void) throws -> (() -> Void) {
        let id = UUID()
        try withCleanupFailoverGrant(grant, operationID: operationID) { failoverCancellations[id] = cancel }
        return { [weak self] in _ = self?.lock.withLock { self?.failoverCancellations.removeValue(forKey: id) } }
    }
    public var cleanupFailoverIsPaused: Bool { lock.withLock { failoverPaused } }
    public func reviewCleanupFailover(backups: [CleanupBackup]) throws -> CleanupFailoverReview {
        try lock.withLock {
            let (original, settings) = try strictFailoverLocked(narrow: true)
            let primary = try CleanupChainIdentity.primary(settings)
            let policy = CleanupFailoverPolicy(backups: backups)
            _ = try policy.digest(primary: primary)
            return CleanupFailoverReview(original: original, policy: policy, primary: primary)
        }
    }
    @discardableResult public func confirmCleanupFailover(_ review: CleanupFailoverReview) throws -> CleanupFailoverPolicy {
        let committed = try lock.withLock {
            let (original, settings) = try strictFailoverLocked(narrow: true)
            guard original == review.original, try CleanupChainIdentity.primary(settings) == review.primary else { throw CleanupFailoverFailure.changed }
            var policy = review.policy; try policy.confirm(primary: review.primary)
            try writeFailoverLocked(policy, original: original)
            revokeFailoverLocked(); failoverObserved = authoritySignature(try JSONDecoder().decode(Settings.self, from: try readSettingsBytes()))
            failoverPaused = false
            return policy
        }
        NotificationCenter.default.post(name: Self.configurationDidChange, object: self); return committed
    }
    @discardableResult public func editCleanupFailover(backups: [CleanupBackup], expected: CleanupFailoverPolicy?) throws -> CleanupFailoverPolicy {
        revokeCleanupFailover()
        let committed = try lock.withLock {
            let (original, settings) = try strictFailoverLocked(narrow: true)
            guard settings.cleanupFailover == expected else { throw CleanupFailoverFailure.changed }
            let policy = CleanupFailoverPolicy(backups: backups); try policy.validate()
            try writeFailoverLocked(policy, original: original); return policy
        }
        NotificationCenter.default.post(name: Self.configurationDidChange, object: self); return committed
    }
    @discardableResult public func disableCleanupFailover(expected: CleanupFailoverPolicy?) throws -> CleanupFailoverPolicy? {
        // Intent revokes even if the strict read or write fails.
        revokeCleanupFailover()
        let committed = try lock.withLock {
            let (original, settings) = try strictFailoverLocked(narrow: true)
            guard settings.cleanupFailover == expected else { throw CleanupFailoverFailure.changed }
            var policy = settings.cleanupFailover; policy?.review = nil
            try writeFailoverLocked(policy, original: original); return policy
        }
        NotificationCenter.default.post(name: Self.configurationDidChange, object: self); return committed
    }
    private func writeFailoverLocked(_ policy: CleanupFailoverPolicy?, original: Data) throws {
        guard var object = try JSONSerialization.jsonObject(with: original) as? [String: Any] else { throw CleanupFailoverFailure.configuration }
        object["cleanupFailover"] = try policy.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard bytes.count <= ScratchpadPreferenceIO.maxBytes else { throw CleanupFailoverFailure.configuration }
        _ = try JSONDecoder().decode(Settings.self, from: bytes)
        let current = documentIO == nil ? try readFailoverObservedNarrowLocked() : try optionalSettingsBytes()
        guard current == original else { throw CleanupFailoverFailure.changed }
        if documentIO == nil { try scratchpadIO.write(bytes, url) } else { try atomicWrite(bytes, url) }
        observeSurroundingTextBytesLocked(bytes)
        cached = nil
    }

    // Independent B26 raw authority. Every actual byte read observes it, even
    // when the enclosing CAS/credential action later fails. No await under lock.
    private func revokeSurroundingTextLocked() {
        precondition(contextEpoch < UInt64.max)
        contextEpoch += 1; contextPaused = true
        let actions = Array(contextCancellations.values); contextCancellations.removeAll()
        actions.forEach { $0() }
    }
    private func observeSurroundingTextBytesLocked(_ bytes: Data?) {
        let signature = SurroundingTextAuthority.observation(bytes)
        if signature == nil || (contextObserved != nil && contextObserved != signature) { revokeSurroundingTextLocked() }
        contextObserved = signature
        if let bytes {
            do { _ = try SurroundingTextAuthority.policy(bytes) }
            catch { revokeSurroundingTextLocked() }
        } else { revokeSurroundingTextLocked() }
    }
    public func revokeSurroundingTextContext() { lock.withLock { revokeSurroundingTextLocked() } }
    public var surroundingTextIsPaused: Bool { lock.withLock { contextPaused } }
    public func observeSurroundingTextDraft(from old: Settings, to new: Settings) {
        if SurroundingTextAuthority.draftSignature(old) != SurroundingTextAuthority.draftSignature(new) { revokeSurroundingTextContext() }
    }
    private func contextDocumentLocked(narrow: Bool = true) throws -> Data {
        let bytes = narrow && documentIO == nil ? try readFailoverObservedNarrowLocked() : try optionalSettingsBytes()
        guard let bytes, !narrow || bytes.count <= ScratchpadPreferenceIO.maxBytes else {
            revokeSurroundingTextLocked(); throw SurroundingTextFailure.refused
        }
        return bytes
    }
    /// Metadata only, used by preparePhysicalStart before recognition/queueing.
    /// The nonencoded carrier is consumed into Session, never saved or inherited.
    public func preparingPhysicalSurroundingText(_ settings: Settings, destination: ProfileDestination,
                                                live: Bool = false) -> Settings {
        var snapshot = settings
        snapshot.physicalSurroundingTextGrant = capturePhysicalSurroundingTextGrant(settings: settings, destination: destination, live: live)
        return snapshot
    }
    public func capturePhysicalSurroundingTextGrant(settings: Settings, destination: ProfileDestination,
                                                    live: Bool = false) -> SurroundingTextGrant? {
        lock.withLock {
            guard !live, settings.outputMode == .cleanup, settings.cleanupEnabled,
                  let bytes = try? contextDocumentLocked(), !contextPaused,
                  let policy = try? SurroundingTextAuthority.policy(bytes), policy.reviewed,
                  let current = try? JSONDecoder().decode(Settings.self, from: bytes),
                  SurroundingTextAuthority.draftSignature(current) == SurroundingTextAuthority.draftSignature(settings) else { return nil }
            let winner = ProfileResolver.resolve(settings, at: destination)
            guard destination.bundleID == policy.target, destination.host == nil,
                  winner.profile?.id == policy.profileID,
                  (try? CleanupChainIdentity.primary(winner.settings)) == policy.primary else { return nil }
            return SurroundingTextGrant(epoch: contextEpoch, policy: policy)
        }
    }
    public func withSurroundingTextGrant<T>(_ grant: SurroundingTextGrant, operationID: UUID,
                                            _ action: () throws -> T) throws -> T {
        try lock.withLock {
            let bytes = try contextDocumentLocked()
            guard !contextPaused, grant.epoch == contextEpoch, grant.operationID == operationID,
                  let policy = try SurroundingTextAuthority.policy(bytes), policy.reviewed, policy == grant.policy else { throw SurroundingTextFailure.refused }
            return try action()
        }
    }
    public func subscribeSurroundingText(_ grant: SurroundingTextGrant, operationID: UUID,
                                        cancel: @escaping () -> Void) throws -> (() -> Void) {
        let token = UUID()
        try withSurroundingTextGrant(grant, operationID: operationID) { contextCancellations[token] = cancel }
        return { [weak self] in _ = self?.lock.withLock { self?.contextCancellations.removeValue(forKey: token) } }
    }
    public func reviewSurroundingText(profileID: UUID) throws -> SurroundingTextReview {
        try lock.withLock {
            let bytes = try contextDocumentLocked(narrow: true)
            return SurroundingTextReview(original: bytes, policy: try SurroundingTextAuthority.candidate(bytes, profileID: profileID))
        }
    }
    @discardableResult public func confirmSurroundingText(_ review: SurroundingTextReview) throws -> SurroundingTextPolicy {
        let policy = try lock.withLock {
            let bytes = try contextDocumentLocked(narrow: true)
            guard bytes == review.original,
                  try SurroundingTextAuthority.candidate(bytes, profileID: review.policy.profileID) == review.policy else { throw SurroundingTextFailure.refused }
            var policy = review.policy; policy.revision = UUID(); policy.digest = try policy.hash()
            try writeSurroundingTextLocked(policy, original: bytes)
            revokeSurroundingTextLocked()
            let committed = try contextDocumentLocked(narrow: true)
            guard try SurroundingTextAuthority.policy(committed) == policy else { throw SurroundingTextFailure.refused }
            contextPaused = false; return policy
        }
        NotificationCenter.default.post(name: Self.configurationDidChange, object: self)
        return policy
    }
    /// Edit is a new unreviewed choice, never an authorization for held work.
    @discardableResult public func editSurroundingText(_ review: SurroundingTextReview) throws -> SurroundingTextPolicy {
        revokeSurroundingTextContext()
        let policy = try lock.withLock {
            let bytes = try contextDocumentLocked(narrow: true)
            guard bytes == review.original else { throw SurroundingTextFailure.refused }
            try writeSurroundingTextLocked(review.policy, original: bytes); return review.policy
        }
        NotificationCenter.default.post(name: Self.configurationDidChange, object: self); return policy
    }
    public func disableSurroundingText() throws {
        revokeSurroundingTextContext()
        try lock.withLock {
            let bytes = try contextDocumentLocked(narrow: true)
            try writeSurroundingTextLocked(nil, original: bytes)
        }
        NotificationCenter.default.post(name: Self.configurationDidChange, object: self)
    }
    public func disableSurroundingText(_ review: SurroundingTextReview) throws {
        revokeSurroundingTextContext() // failed Disable still closes held work.
        try lock.withLock {
            let bytes = try contextDocumentLocked(narrow: true)
            guard bytes == review.original else { throw SurroundingTextFailure.refused }
            try writeSurroundingTextLocked(nil, original: bytes)
        }
        NotificationCenter.default.post(name: Self.configurationDidChange, object: self)
    }
    private func writeSurroundingTextLocked(_ policy: SurroundingTextPolicy?, original: Data) throws {
        var root = try SurroundingTextAuthority.object(original)
        root[SurroundingTextAuthority.key] = try policy.map { try JSONSerialization.jsonObject(with: SurroundingTextAuthority.encode($0)) }
        let bytes = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        guard bytes.count <= ScratchpadPreferenceIO.maxBytes, try contextDocumentLocked(narrow: true) == original else { throw SurroundingTextFailure.refused }
        if documentIO == nil { try scratchpadIO.write(bytes, url) } else { try atomicWrite(bytes, url) }
        cached = nil
    }

    private func rejectNewInline(_ settings: Settings) throws {
        // Old in-memory snapshots after a successful migration may still contain the
        // matching value. Verify those, too; never silently redact the only source.
        if let key = settings.anthropicApiKey, !key.isEmpty { try verifyExisting(key, scope: .anthropic) }
        if let key = settings.cleanup.apiKey, !key.isEmpty {
            try verifyExisting(key, scope: CredentialScope.compatible(settings.cleanup.baseURL))
        }
    }

    private func verifyExisting(_ key: String, scope: CredentialScope) throws {
        guard case .value(let existing) = credentials.read(scope, interactive: false), existing == key else {
            throw CredentialFailure("Inline credentials cannot be saved. Use AI Cleanup Save/Replace; original settings preserved.")
        }
    }

    private func write(_ settings: Settings, expectedOriginal: Data?, contextBase: Settings? = nil) throws {
        try prepareSettingsParent()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let output = try SurroundingTextAuthority.preserving(expectedOriginal, in: enc.encode(settings), base: contextBase, incoming: settings)
        guard try optionalSettingsBytes() == expectedOriginal else { throw CleanupFailoverFailure.changed }
        try atomicWrite(output, url)
        observeSurroundingTextBytesLocked(output)
        // Don't trust the stamp to notice our own write — an atomic replace can
        // land in the same second at the same length as what it replaced.
    }
}

extension Settings {
    public var usesAppleIntelligence: Bool { cleanup.provider == "apple-intelligence" }
    public var cleanupModelLabel: String { usesAppleIntelligence ? "Apple Intelligence · on-device" : cleanup.provider == "openai-compatible" ? (cleanup.model ?? "server chooses") : cleanupModel }
}
