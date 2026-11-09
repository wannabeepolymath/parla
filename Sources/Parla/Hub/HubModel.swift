import AppKit
import AVFoundation
import Combine
import ParlaCore
import ServiceManagement
import UniformTypeIdentifiers

/// UI state for the Hub window, bridging the existing stores. Main-thread only
/// (same contract as HUD) — mutations come from SwiftUI or AppDelegate on main.
final class HubModel: ObservableObject {
    struct WordRow: Identifiable, Equatable {
        let id = UUID()
        var text = ""
    }
    struct SnippetRow: Identifiable, Equatable {
        let id = UUID()
        var trigger = ""
        var expansion = ""
    }

    struct ReplacementRow: Identifiable, Equatable {
        let id = UUID()
        var source = ""
        var replacement = ""
    }

    let microphoneTest: MicrophoneTestController
    let store: SettingsStore
    let history: HistoryStore
    var audioImportPageActive = false
    let templates: GuidedTemplateOwner
    var templatesPageActive = false
    @Published var templateDocument = GuidedTemplateDocument()
    @Published var selectedTemplateID: UUID?
    @Published var templateEditor: GuidedTemplateDefinition?
    var templateEditorBase: UUID?
    @Published var templateMessage: String?
    private var templateObserver: AnyCancellable?
    let audioImport: AudioImportOwner
    var savedAudioImport: SavedAudioImportOwner? { audioImport.savedImports }
    var vocabularyExportPanel: () -> URL? = {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "parla-vocabulary.json"
        return panel.runModal() == .OK ? panel.url : nil
    }
    var vocabularyExportWriter: (Data, URL) throws -> Void = { try $0.write(to:$1,options:.atomic) }
    var audioImportPicker: () -> URL? = HubModel.selectAudioImportURL
    var audioImportPreparationEpoch: () -> UUID? = { nil }
    var audioImportExportPanel: (String) -> URL? = HubModel.selectAudioImportExportURL
    var onAudioImport: (AudioImportOwner.Job, @escaping (Result<AudioImportOwner.Completed, Error>) -> Void) -> Void = { job, done in
        job.source.cancel(); job.operation.finish()
        done(.failure(RecordingStore.Failure("Transcription isn't available.")))
    }
    // Wired by AppDelegate to its existing actions.
    var modelSelectionEpoch = UUID()
    @Published var parakeetSnapshot = ParakeetSnapshot() { didSet {
        if oldValue != parakeetSnapshot { templates.preparationChanged() }
        if audioImport.job?.configuration.request.selection.engine == .parakeet || savedAudioImport?.currentEngine == .parakeet,
           (parakeetSnapshot.refusal != nil && parakeetSnapshot.refusal != .configuration && oldValue.refusal != parakeetSnapshot.refusal
            || oldValue.phase == .ready && (parakeetSnapshot.phase == .installed || parakeetSnapshot.phase == .blocked) && parakeetSnapshot.refusal != .configuration) {
            audioImport.invalidate("Speech settings changed. Choose the file again.")
        }
    } }
    private var parakeetObserver: AnyCancellable?
    private weak var parakeetOwner: ParakeetPreparation?
    var parakeetChoiceRefusal: ParakeetInstallationRefusal? {
        MainActor.assumeIsolated { parakeetOwner?.choiceRefusal ?? (parakeetOwner == nil ? .releaseIntegrity : nil) }
    }
    var parakeetProfileChoiceRefusal: ParakeetInstallationRefusal? {
        guard loadError == nil, saveError == nil else { return .configuration }
        return MainActor.assumeIsolated { parakeetOwner?.profileChoiceRefusal ?? (parakeetOwner == nil ? .releaseIntegrity : nil) }
    }
    func parakeetControlSnapshot(_ id: ParakeetPreparation.TargetID) -> ParakeetSnapshot {
        MainActor.assumeIsolated { parakeetOwner?.controlSnapshot(for: id) ?? parakeetSnapshot }
    }
    func parakeetTarget(_ id: ParakeetPreparation.TargetID) -> ParakeetPreparation.SavedTarget? {
        guard loadError == nil, saveError == nil else { return nil }
        return MainActor.assumeIsolated { parakeetOwner?.savedTarget(id) }
    }
    func parakeetAction(_ action: ParakeetPreparation.Action, target: ParakeetPreparation.SavedTarget) {
        guard loadError == nil, saveError == nil else { return }
        templates.cancel("Form canceled."); audioImport.invalidate("Speech settings changed. Choose the file again.")
        MainActor.assumeIsolated { meetingHub?.revokePreparation(.parakeet); parakeetOwner?.act(action, target: target) }
    }
    /// Only a successful disk save/reload (or explicit fresh load) grants targets.
    private func reloadParakeetConfiguration() {
        guard let parakeetOwner else { return }
        let saved = store.load()
        MainActor.assumeIsolated { parakeetOwner.configure(saved, valid: store.lastError == nil && saveError == nil) }
    }
    var onParakeetAction: (ParakeetPreparation.Action, UUID) -> Void = { _, _ in }
    var onParakeetCancel: (UUID) -> Void = { _ in }
    var onParakeetDraftChanged: () -> Void = {}
    @MainActor func bindParakeet(_ owner: ParakeetPreparation) {
        parakeetOwner = owner
        reloadParakeetConfiguration()
        parakeetSnapshot = owner.snapshot
        parakeetObserver = owner.$snapshot.sink { [weak self] in self?.parakeetSnapshot = $0 }
        onParakeetAction = { [weak self, weak owner] action, token in
            guard let self, self.loadError == nil, self.saveError == nil else { return }
            guard let target = owner?.savedTarget(.global), target.admissionToken == token else { return }
            self.templates.cancel("Form canceled."); self.audioImport.invalidate("Speech settings changed. Choose the file again.")
            self.meetingHub?.revokePreparation(.parakeet)
            owner?.act(action, target: target)
        }
        onParakeetCancel = { [weak self, weak owner] token in self?.meetingHub?.revokePreparation(.parakeet); self?.audioImport.invalidate("Preparation canceled."); owner?.cancel(token: token) }
        onParakeetDraftChanged = { [weak self,weak owner] in MainActor.assumeIsolated { self?.meetingHub?.revokePreparation(.parakeet); owner?.draftChanged() } }
    }
    @Published var appleSpeechSnapshot = AppleSpeechSnapshot() { didSet {
        if oldValue != appleSpeechSnapshot { templates.preparationChanged() }
        if audioImport.job?.configuration.request.selection.engine == .appleSpeech || savedAudioImport?.currentEngine == .appleSpeech,
           appleSpeechSnapshot.refusal != nil, appleSpeechSnapshot.refusal != .configuration,
           oldValue.refusal != appleSpeechSnapshot.refusal {
            audioImport.invalidate("Speech settings changed. Choose the file again.")
        }
    } }
    private var appleSpeechObserver: AnyCancellable?
    var onAppleSpeechAction: (AppleSpeechPreparation.Action, String, UUID) -> Void = { _, _, _ in }
    var onAppleSpeechCancel: (UUID) -> Void = { _ in }
    var onAppleSpeechDraftChanged: () -> Void = {}
    @MainActor func bindAppleSpeech(_ owner: AppleSpeechPreparation) {
        appleSpeechSnapshot = owner.snapshot
        appleSpeechObserver = owner.$snapshot.sink { [weak self] in self?.appleSpeechSnapshot = $0 }
        onAppleSpeechAction = { [weak self, weak owner] action, locale, token in
            guard let self, let owner else { return }
            guard self.loadError == nil, self.saveError == nil else { return }
            self.templates.cancel("Form canceled."); self.audioImport.invalidate("Speech settings changed. Choose the file again.")
            if action != .recheck { self.meetingHub?.revokePreparation(.appleSpeech) }
            owner.deliberateEntry()
            owner.act(action, locale: locale, token: token)
        }
        onAppleSpeechCancel = { [weak self, weak owner] token in self?.meetingHub?.revokePreparation(.appleSpeech); self?.audioImport.invalidate("Preparation canceled."); owner?.cancel(token: token) }
        onAppleSpeechDraftChanged = { [weak self,weak owner] in MainActor.assumeIsolated { self?.meetingHub?.revokePreparation(.appleSpeech); owner?.draftChanged() } }
    }
    @Published var observedRecognition: (selection: RecognitionSelection, capabilities: RecognitionCapabilities)?
    var recognitionCapabilities: RecognitionCapabilities {
        if settings.recognitionEngine == .appleSpeech { return .appleSpeech }
        if settings.recognitionEngine == .parakeet { return .parakeet }
        guard let observedRecognition,
              observedRecognition.selection == RecognitionRequest(settings: settings).selection else {
            return RecognitionCapabilities()
        }
        return observedRecognition.capabilities
    }
    var recognitionCapabilityDetail: String {
        let engine = RecognitionRequest(settings: settings).selection.engine
        if engine == .appleSpeech || engine == .parakeet { return "Dictionary words are used for cleanup only." }
        if engine == .invalid { return AppleSpeechRefusal.configuration.message }
        return recognitionCapabilities.modelLanguages == .englishOnly ? "This model understands English only." : ""
    }
    @Published var catalogDownloads: [String: CatalogDownloadRow] = [:]
    var onCatalogDownloadAction: (CatalogDownloadAction, ModelCatalog.Model) -> Void = { _, _ in }
    var catalogDownloadObserver: AnyCancellable?
    var onDownloadModel: (ModelCatalog.Model) -> Void = { _ in }
    var onOpenSettingsFile: () -> Void = {}
    var onSaved: () -> Void = {}
    var onRecognitionPreviewRevoked: () -> Void = {}
    /// Passive catalog projection only. Saved missing IDs remain represented.
    var recognitionPreviewChoices: [ModelCatalog.Model] {
        ModelCatalog.all.filter { ModelCatalog.isInstalled($0) }
    }
    var recognitionPreviewUnavailableID: String? {
        guard let id = settings.recognitionPreviewModelID,
              !recognitionPreviewChoices.contains(where: { $0.id == id }) else { return nil }
        return id
    }
    @Published var preparationSnapshot = PreparationSnapshot(.off) { didSet { if oldValue != preparationSnapshot { templates.preparationChanged() } } }
    var onPreparationDraftDisabled: () -> Void = {}
    var onPreparationConsent: (UUID) throws -> Void = { _ in throw PreparationRefusal.trackingUnavailable }
    var onPreparationBeforeSave: (Settings) throws -> Void = { _ in }
    var onPreparationSaved: (Settings) -> Void = { _ in }
    var onPreparationSaveFailed: () -> Void = {}
    var onPreparationSaveDeferred: () -> Void = {}
    var onPreparationSelection: (UUID, RecognitionRequest) -> Void = { _, _ in }
    var onPreparationAction: (NativePreparation.Action, UUID) -> Void = { _, _ in }
    private var requestedPreparationConsent: UUID?
    private var preparedConsent: UUID?
    func setPreparationEnabled(_ value: Bool) {
        if value { requestedPreparationConsent = UUID(); settings.nativePreparationConsent = requestedPreparationConsent }
        else { requestedPreparationConsent = nil; settings.nativePreparationConsent = nil; onPreparationDraftDisabled() }
        settings.nativePreparationSafeStartEnabled = value
    }
    func savePreparationDraft() { save() }
    /// Early controls use settings only; no credential migration, native status, mic, history or model setup.
    func refreshPreparationConfiguration() {
        flushPendingSave()
        loading = true
        defer { loading = false }
        settings = store.load(); settingsBase = settings; loadError = store.lastError
        failoverBackups = settings.cleanupFailover?.backups ?? []; failoverReview = nil
        if !settings.energyActivityShadowEnabled { onActivityShadowRevoked() }
        words = settings.dictionary.map { WordRow(text: $0) }
        snippets = settings.snippets.map { SnippetRow(trigger: $0.key, expansion: $0.value) }
        replacements = settings.replacements.map { ReplacementRow(source: $0.source, replacement: $0.replacement) }
        reloadParakeetConfiguration()
        if loadError == nil { onPreparationSaved(settings) } else { onPreparationSaveFailed() }
    }
    private var originalCopyController: OriginalCopyController?
    private var originalCopyObserver: AnyCancellable?
    @Published private(set) var originalCopyStatus: OriginalCopyStatus = .disabled

    func bindOriginalCopy(_ controller: OriginalCopyController) {
        originalCopyController = controller
        originalCopyObserver = controller.$status.sink { [weak self] in self?.originalCopyStatus = $0 }
        controller.refresh()
    }
    func refreshOriginalCopy() { originalCopyController?.refresh() }
    func clearLastOriginal() { originalCopyController?.clear() }
    func copyLastOriginal() {
        guard let token = originalCopyStatus.token else { return }
        originalCopyController?.copyOriginal(token: token)
    }
    var onScratchpadDictionaryDraftChanged: () -> Void = {}
    private var scratchpadPreferenceObserver: AnyCancellable?
    var onMouseBindingSaved: () -> Void = {}
    var onRetryInput: () -> Void = {}
    @Published var inputTapStatus = InputTapStatus.unavailable
    var onActivityShadowRevoked: () -> Void = {}
    var onCanceledCaptureConfigurationChanged: (Bool) -> Void = { _ in }
    var onCanceledCaptureInvalidate: () -> Void = {}
    var onClearAutomationResult: () -> Void = {}
    var onHistoryCleared: () -> Void = {}
    var onAutomationEnabledChanged: (Bool) -> Void = { _ in }
    /// Onboarding's sandboxed tryout, wired straight to the recorder and whisper
    /// by AppDelegate — never through the dictation machine, so the transcript
    /// can only ever come back here. Start returns why it refused, nil = live.
    var onShortcutBegin: () -> CaptureAdmission.Lease? = { nil }
    var onShortcutEnd: (CaptureAdmission.Lease) -> Void = { _ in }
    var onTryoutCancel: () -> Void = {}
    var onTryoutStart: () -> String? = { "Not available" }
    // @escaping: the completion outlives the call — transcription finishes well
    // after tryoutStop returns.
    var onTryoutStop: (@escaping (String) -> Void) -> Void = { $0("") }

    // The editable draft's base survives unrelated store.load() calls.
    var settingsBase = Settings()
    private var activityShadowDraftTouched = false
    @Published var settings = Settings() { didSet {
        if !loading {
            store.observeCleanupFailoverDraft(from: oldValue, to: settings); failoverReview = nil; failoverMessage = nil
            store.observeSurroundingTextDraft(from: oldValue, to: settings); surroundingReview = nil; surroundingMessage = nil
        }
        if GuidedTemplateOwner.Configuration(oldValue) != GuidedTemplateOwner.Configuration(settings)
            || oldValue.guidedTemplates != settings.guidedTemplates { templates.relevantDraftChanged() }
        if !loading, oldValue != settings { savedAudioImport?.invalidate("Settings changed, so the transcript was closed.") }
        if AudioImportOwner.Configuration(oldValue) != AudioImportOwner.Configuration(settings) {
            audioImport.invalidate("Speech settings changed. Choose the file again.")
        }

        if !loading, oldValue.energyActivityShadowEnabled != settings.energyActivityShadowEnabled { activityShadowDraftTouched = true }
        if !loading, oldValue != settings { onRecognitionPreviewRevoked(); onActivityShadowRevoked() }
        if !loading, oldValue.recognitionEngine != settings.recognitionEngine || oldValue.appleSpeechLocale != settings.appleSpeechLocale || oldValue.parakeetModelID != settings.parakeetModelID || oldValue.parakeetLanguageFilter != settings.parakeetLanguageFilter || oldValue.profiles != settings.profiles {
            onAppleSpeechDraftChanged()
        }
        if !loading, oldValue.whisperModelPath != settings.whisperModelPath || oldValue.recognitionEngine != settings.recognitionEngine || oldValue.appleSpeechLocale != settings.appleSpeechLocale || oldValue.parakeetModelID != settings.parakeetModelID || oldValue.parakeetLanguageFilter != settings.parakeetLanguageFilter {
            modelSelectionEpoch = UUID()
            onPreparationSelection(modelSelectionEpoch, RecognitionRequest(settings: settings))
        }
        if !loading, oldValue.nativePreparationSafeStartEnabled, !settings.nativePreparationSafeStartEnabled { onPreparationDraftDisabled() }
        if !loading, !settings.canceledCaptureUndoEnabled { onCanceledCaptureInvalidate() }
        if !loading, oldValue.keepLastOriginalEnabled != settings.keepLastOriginalEnabled,
           !settings.keepLastOriginalEnabled { clearLastOriginal() }
        if !loading, settings.automationEnabled != oldValue.automationEnabled { onAutomationEnabledChanged(settings.automationEnabled) }
        if oldValue.cleanup.provider != settings.cleanup.provider || oldValue.cleanup.baseURL != settings.cleanup.baseURL {
            credentialDraft = ""
            credentialMessage = store.migrationError
            if !loading {
                refreshCredentialStatus()
                if settings.usesAppleIntelligence { recheckLocalCleanup() }
            }
        }
        if oldValue.cleanup.localSourceLocale != settings.cleanup.localSourceLocale { localCleanupStatus = .unknown }
        if !loading, oldValue.dictionary != settings.dictionary || oldValue.snippets != settings.snippets || oldValue.replacements != settings.replacements {
            onScratchpadDictionaryDraftChanged()
        }
        var oldWithoutShadow = oldValue; oldWithoutShadow.energyActivityShadowEnabled = false
        var newWithoutShadow = settings; newWithoutShadow.energyActivityShadowEnabled = false
        let onlyShadow = oldValue.energyActivityShadowEnabled != settings.energyActivityShadowEnabled && oldWithoutShadow == newWithoutShadow
        touch(invalidateParakeet: !onlyShadow)
    } }
    @Published var failoverBackups: [CleanupBackup] = [] { didSet {
        if !loading, oldValue != failoverBackups {
            store.revokeCleanupFailover(); failoverReview = nil; failoverMessage = nil
        }
    } }
    @Published private(set) var surroundingReview: SurroundingTextReview?
    @Published private(set) var surroundingPolicy: SurroundingTextPolicy?
    @Published var surroundingMessage: String?
    var surroundingState: String {
        guard let policy = surroundingPolicy, policy.revision != nil else { return "Off for online cleanup" }
        return store.surroundingTextIsPaused ? "Paused — turn it on again to resume" : "On for " + policy.target
    }
    func surroundingDraftChanged() {
        store.revokeSurroundingTextContext(); surroundingReview = nil; surroundingMessage = nil
    }
    func surroundingProfileDraftChanged(from old: DictationProfile, to new: DictationProfile) {
        if old != new { surroundingDraftChanged() }
    }
    private func surroundingActionReady() -> Bool {
        guard !hasPendingSettingsSave, loadError == nil, saveError == nil,
              settings.outputMode == .cleanup, settings.cleanupEnabled, !settings.usesAppleIntelligence,
              settings.cleanupFailover == nil else {
            surroundingReview = nil
            surroundingMessage = "Nearby text needs an online cleanup provider, output set to Cleaned up, and no backup cleanup."
            return false
        }
        return true
    }
    func reviewSurrounding(profileID: UUID) {
        guard surroundingActionReady() else { return }
        do { surroundingReview = try store.reviewSurroundingText(profileID: profileID); surroundingMessage = nil }
        catch { surroundingReview = nil; surroundingMessage = "Save this profile and your cleanup settings first." }
    }
    func confirmSurrounding() {
        guard surroundingActionReady(), let review = surroundingReview else { return }
        do {
            surroundingPolicy = try store.confirmSurroundingText(review)
            surroundingReview = nil
            surroundingMessage = "Nearby text is on for this app."
        } catch { surroundingReview = nil; surroundingMessage = "Settings changed. Try again." }
    }
    func disableSurrounding(profileID: UUID) {
        // Intent revokes even if strict review or exact byte CAS subsequently fails.
        surroundingDraftChanged()
        do {
            try store.disableSurroundingText()
            surroundingPolicy = nil; surroundingMessage = "Nearby text is off."
        } catch { surroundingMessage = "Paused, but couldn't save. Fix settings.json and turn it off again." }
    }
    func surroundingDisclosure(_ policy: SurroundingTextPolicy) -> String {
        "With each dictation in \(policy.target), Parla will send about 256 characters of text before the cursor — text you didn’t dictate — "
        + "to \(policy.primary.provider) (\(policy.primary.endpoint), model \(policy.primary.model)). Text after the cursor is never sent, and nearby text isn’t saved. "
        + "Changing this profile or your cleanup settings pauses this until you turn it on again."
    }

    @Published private(set) var failoverReview: CleanupFailoverReview?
    @Published var failoverMessage: String?
    @Published private var failoverKeyDrafts: [CredentialScope: String] = [:]
    private func failoverKeyScope(_ index: Int) -> CredentialScope? {
        guard failoverBackups.indices.contains(index) else { return nil }
        let row = failoverBackups[index]
        return row.provider == "anthropic" ? .anthropic : try? CredentialScope.compatible(row.baseURL)
    }
    func failoverKeyDraft(_ index: Int) -> String { failoverKeyScope(index).flatMap { failoverKeyDrafts[$0] } ?? "" }
    func setFailoverKeyDraft(_ index: Int, _ value: String) {
        guard let scope = failoverKeyScope(index) else { return }
        failoverKeyDrafts[scope] = value
    }
    private var failoverPrerequisiteMessage: String? {
        guard settings.outputMode == .cleanup, settings.cleanupEnabled else {
            return "Backups need cleanup turned on and Dictation output set to Cleaned up (Output & Presets)."
        }
        return nil
    }
    var failoverState: String {
        guard let policy = settings.cleanupFailover, policy.review != nil else { return "Off" }
        if let message = failoverPrerequisiteMessage { return "Paused — " + message }
        guard policy.isReviewed(for: settings), !store.cleanupFailoverIsPaused else { return "Paused — review backups to turn them back on" }
        return "On (except for profiles with their own cleanup model)"
    }
    private func failoverEligibilityReady() -> Bool {
        guard let message = failoverPrerequisiteMessage else { return true }
        failoverReview = nil; failoverMessage = message
        return false
    }
    private func failoverActionReady() -> Bool {
        guard !hasPendingSettingsSave, loadError == nil, saveError == nil else {
            failoverReview = nil
            failoverMessage = "Wait for settings to save, then try again."
            return false
        }
        return true
    }
    func reviewFailover() {
        guard failoverActionReady(), failoverEligibilityReady() else { return }
        do {
            failoverReview = try store.reviewCleanupFailover(backups: failoverBackups)
            failoverMessage = nil
        } catch { failoverReview = nil; failoverMessage = "Couldn't check backups. Review each one's server, model and key." }
    }
    func confirmFailover() {
        guard failoverActionReady(), failoverEligibilityReady(), let review = failoverReview else { return }
        do {
            let policy = try store.confirmCleanupFailover(review)
            adoptFailover(policy); failoverMessage = "Backups are on."
        } catch { failoverReview = nil; failoverMessage = "Settings changed. Review backups again." }
    }
    func saveFailoverDraft() {
        guard failoverActionReady() else { return }
        do {
            let policy = try store.editCleanupFailover(backups: failoverBackups, expected: settings.cleanupFailover)
            adoptFailover(policy); failoverMessage = "Backups saved. Review them to turn them on."
        } catch { failoverMessage = "Couldn't save backups. Check each server and try again." }
    }
    func disableFailover() {
        // Revocation is immediate even on a disk fault; ordinary debounce stays owed.
        do {
            let policy = try store.disableCleanupFailover(expected: settings.cleanupFailover)
            adoptFailover(policy); failoverMessage = "Backups are off."
        } catch { failoverReview = nil; failoverMessage = "Backups are paused, but couldn't save. Fix settings.json and turn them off again." }
    }
    func loadFailoverDraft() {
        guard failoverActionReady() else { return }
        do { adoptFailover(try store.savedRetrySnapshot().cleanupFailover) }
        catch { failoverMessage = "Couldn't load saved backups. Fix settings.json." }
    }
    private func adoptFailover(_ policy: CleanupFailoverPolicy?) {
        let wasLoading = loading; loading = true
        settings.cleanupFailover = policy; settingsBase.cleanupFailover = policy
        failoverBackups = policy?.backups ?? []; failoverReview = nil
        loading = wasLoading
    }
    func moveFailoverBackup(_ index: Int, by offset: Int) {
        guard failoverBackups.indices.contains(index), failoverBackups.indices.contains(index + offset) else { return }
        failoverBackups.swapAt(index, index + offset)
    }
    func changeFailoverKey(_ index: Int, remove: Bool = false) {
        guard loadError == nil, saveError == nil, failoverBackups.indices.contains(index),
              remove || !failoverKeyDraft(index).isEmpty else { return }
        do {
            let row = failoverBackups[index]; try row.validate()
            guard row.source == .scopedKeychain else { throw CleanupFailoverFailure.configuration }
            let scope = row.provider == "anthropic" ? CredentialScope.anthropic : try CredentialScope.compatible(row.baseURL)
            try store.changeCredential(scope: scope, replacement: remove ? nil : failoverKeyDraft(index))
            failoverKeyDrafts.removeValue(forKey: scope); failoverMessage = "Key updated."
        } catch { failoverMessage = "Couldn't update the key. Check the server and try again." }
    }
    @Published var localCleanupStatus: LocalCleanupReason? = .unknown
    var localCleanupRuntime = LocalCleanupRuntime()
    func recheckLocalCleanup() {
        localCleanupStatus = localCleanupRuntime.recheck(LocalCleanupConfiguration(settings: settings))
    }
    @Published var credentialDraft = ""
    @Published var credentialStatus = ""
    @Published var credentialIssue: String?
    @Published var credentialMessage: String?
    var credentialEnvironment: () -> [String: String] = { ProcessInfo.processInfo.environment }

    func refreshCredentialStatus() {
        credentialStatus = cleanupCredentialSource(settings: settings, env: credentialEnvironment(), credentials: store.credentials)
        credentialIssue = cleanupConfigurationIssue(settings: settings, env: credentialEnvironment(), credentials: store.credentials)
    }

    func retryCredentialMigration() {
        flushPendingSave()
        credentialMessage = store.migrateCredentials()
        if credentialMessage == nil {
            loading = true
            settings.anthropicApiKey = nil; settings.cleanup.apiKey = nil
            settingsBase.anthropicApiKey = nil; settingsBase.cleanup.apiKey = nil
            loading = false
            if saveError != nil { touch() }
        }
        refreshCredentialStatus()
    }

    func saveCredential() { changeCredential(remove: false) }
    func removeCredential() { changeCredential(remove: true) }
    private func changeCredential(remove: Bool) {
        guard loadError == nil else { credentialMessage = "Fix settings.json before changing keys."; return }
        guard remove || !credentialDraft.isEmpty else { return }
        flushPendingSave()
        guard saveError == nil || store.migrationError != nil else {
            credentialMessage = "Fix the settings error before changing keys."
            return
        }
        do {
            let scope = try CredentialScope.selected(settings)
            try store.changeCredential(scope: scope, replacement: remove ? nil : credentialDraft)
            credentialDraft = ""
            // Never rehydrate a secret or replace unsaved endpoint/model drafts.
            if scope == .anthropic { settings.anthropicApiKey = nil }
            else { settings.cleanup.apiKey = nil }
            credentialMessage = store.migrateCredentials()
        } catch { credentialMessage = (error as? CredentialFailure)?.description ?? "Couldn't update the key. Try again." }
        refreshCredentialStatus()
    }

    @Published var words: [WordRow] = [] { didSet { if !loading { surroundingDraftChanged(); templates.relevantDraftChanged(); onScratchpadDictionaryDraftChanged(); audioImport.invalidate("Dictionary changed. Choose the file again.") }; touch() } }
    @Published var snippets: [SnippetRow] = [] { didSet { if !loading { surroundingDraftChanged(); onScratchpadDictionaryDraftChanged(); audioImport.invalidate("Dictionary changed. Choose the file again.") }; touch() } }
    @Published var replacements: [ReplacementRow] = [] { didSet { if !loading { surroundingDraftChanged(); onScratchpadDictionaryDraftChanged(); audioImport.invalidate("Dictionary changed. Choose the file again.") }; touch() } }
    @Published var importPreview: VocabularyImportPreview?
    @Published var transferMessage: String?
    /// settings.json decode error. Editing is disabled while non-nil so the hub
    /// never clobbers a file the user needs to hand-fix (same rule as the menu).
    @Published var loadError: String? { didSet { if loadError != nil { surroundingDraftChanged(); store.revokeCleanupFailover(); failoverReview = nil; templates.cancel("Settings unavailable."); audioImport.invalidate("Settings can't be read."); onActivityShadowRevoked(); onScratchpadDictionaryDraftChanged(); onParakeetDraftChanged() } } }
    @Published var saveError: String? { didSet { if saveError != nil { surroundingDraftChanged(); store.revokeCleanupFailover(); failoverReview = nil; templates.cancel("Settings save failed."); audioImport.invalidate("Settings could not be saved."); onActivityShadowRevoked(); onScratchpadDictionaryDraftChanged(); onParakeetDraftChanged() } } }
    @Published var modelLoaded = false
    @Published var downloadProgress: Double? // non-nil while downloading
    @Published var downloadingModel: ModelCatalog.Model?
    /// Why the last download failed, nil once another one starts.
    @Published var downloadError: String?
    @Published var historyEntries: [HistoryEntry] = []
    @Published var pendingHistory: [HistoryEntry] = []
    @Published var historyError: String?
    @Published var historyExport: HistoryExportRequest?
    @Published var historyExportMessage: String?
    let diagnostics: DiagnosticStore
    @Published var diagnosticReview: Data?
    @Published var diagnosticMessage: String?
    var diagnosticPanel: (DiagnosticSaveRequest) -> URL? = DiagnosticSaveRequest.select
    var diagnosticWriter: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    let recordings: RecordingStore
    let recoveryPlayback = RecoveryPlayback()
    @Published var recoveryRows: [RecordingStore.Descriptor] = []
    @Published var recordingSummary = RecordingStore.Summary(count: 0, bytes: 0)
    @Published var recoveryMessage: String?
    @Published var recoveryPolicyStatus: String?
    @Published var recoveryStoreError: String?
    @Published var recoveryPreview: RecoveryPreview?
    @Published var playingRecordingID: String?
    var recoveryClock: () -> Date = Date.init
    var onRecoveryTranscribe: (RecordingStore.Lease, RecognitionRequest, @escaping (Result<String, Error>) -> Void) -> Void = { _, _, done in
        done(.failure(RecordingStore.Failure("Transcription isn't available.")))
    }
    private var recordingObserver: AnyCancellable?
    let recordingDirectory: URL
    var historyExportPanel: (HistoryExportSaveRequest) -> URL? = HistoryExportSaveRequest.select
    var historyExportWriter: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    var historyExportClock: () -> Date = Date.init
    var historyRetryTasks: [UUID: Task<Result<(String, HistoryRetryProvenance), Error>, Never>] = [:]
    var recoveryOperation: PendingOperation?
    var recoveryLease: RecordingStore.Lease?
    @Published var historyRetries: [UUID: HistoryRetryPreview] = [:]
    @Published var historyRetryMessage: String?
    var retryEnvironment: () -> [String: String] = { ProcessInfo.processInfo.environment }
    var localRetryScheduler: LocalHistoryRetryScheduler?
    var retryFactory: HistoryRetryRequest.Factory
    var retryClock: () -> Date = Date.init
    let experimentalRetryOwner: ExperimentalHistoryRetryOwner
    var segmentedRetryFactory: HistoryRetryRequest.SegmentedFactory
    var segmentedRetryNow: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var segmentedRetrySleep: (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }

    @Published var requestedPage: HubPage? { didSet { if let requestedPage, requestedPage != .templates { templates.cancel("Form canceled."); cancelTemplateEditor() } } }
    private var historyObserver: AnyCancellable?
    private let clipboard: ((String) -> Void)?
    @Published var launchAtLogin = false
    @Published var micGranted = false
    @Published var axGranted = false
    /// Why the last recorded shortcut was refused, nil when nothing was.
    @Published var lastRecognitionProfile: String?
    @Published var lastOutputProfile: String?
    @Published var presetError: String?
    @Published var profileError: String?
    @Published var hotkeyError: String? {
        didSet { if hotkeyError == nil { hotkeyRefusal = nil } }
    }
    private var hotkeyRefusal: (bindings: HotkeyBindings, attempted: KeyChord?)?
    let shortcutLabels: ShortcutLabels
    @Published private(set) var shortcutRevision = 0
    private var shortcutObserver: AnyCancellable?

    func shortcutDisplay(_ chord: KeyChord) -> String { shortcutLabels.formatter.display(chord) }
    func shortcutDisplay(_ chord: KeyChord?) -> String { chord.map(shortcutDisplay) ?? "Unbound" }
    var commandShortcutDisplay: String { "⇧ " + shortcutDisplay(settings.hotkeys.pushToTalk) }

    private func refreshHotkeyError() {
        guard let refusal = hotkeyRefusal, let problem = refusal.bindings.problem(display: shortcutDisplay) else { return }
        hotkeyError = refusal.attempted.map { "\(shortcutDisplay($0)) won't work — \(problem)." } ?? problem
    }

    var loading = false
    private var saveItem: DispatchWorkItem?
    var hasPendingSettingsSave: Bool { saveItem != nil }

    var meetingPageActive = false
    let meetingHub: MeetingHubController?
    init(store: SettingsStore, history: HistoryStore, clipboard: ((String) -> Void)? = nil,
         recordings: RecordingStore = .shared, shortcutLabels: ShortcutLabels = ShortcutLabels(),
         retryHTTP: @autoclosure @escaping () -> HTTPPosting = URLSessionPoster(), diagnostics: DiagnosticStore = .shared,
         microphoneTest: MicrophoneTestController = MicrophoneTestController(),
         experimentalRetryOwner: ExperimentalHistoryRetryOwner = ExperimentalHistoryRetryOwner(),
         audioImport: AudioImportOwner = AudioImportOwner(), templates: GuidedTemplateOwner = GuidedTemplateOwner(), meetingHub: MeetingHubController? = nil) {
        self.meetingHub = meetingHub
        self.templates = templates
        self.audioImport = audioImport
        self.experimentalRetryOwner = experimentalRetryOwner
        self.microphoneTest = microphoneTest
        self.diagnostics = diagnostics
        self.shortcutLabels = shortcutLabels
        self.store = store
        self.retryFactory = { settings, environment, access, usage in
            try makeCleanupClient(settings: settings, env: environment, credentials: store.credentials, access: access, http: retryHTTP(), usage: usage)
        }
        self.segmentedRetryFactory = { settings, environment, access, policy, usage in
            try makeCleanupClient(settings: settings, env: environment, credentials: store.credentials,
                                  access: access, http: HistoryRetryHTTP(policy: policy), executionPolicy: policy, usage: usage)
        }
        self.history = history
        self.clipboard = clipboard
        self.recordings = recordings
        self.recordingDirectory = recordings.directory
        audioImport.bind(store)
        shortcutObserver = shortcutLabels.$revision.sink { [weak self] revision in
            self?.shortcutRevision = revision
            self?.refreshHotkeyError()
        }
        // Repeated disk errors are deduplicated by the store to bound refresh notifications.
        recordingObserver = NotificationCenter.default.publisher(for: RecordingStore.didChange, object: recordings)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshRecoveryProjection() }
        historyObserver = NotificationCenter.default.publisher(for: HistoryStore.didChange, object: history)
            .sink { [weak self] _ in self?.refreshHistory() }
        scratchpadPreferenceObserver = NotificationCenter.default.publisher(for: SettingsStore.scratchpadPreferenceDidChange, object: store)
            .sink { [weak self] note in
                guard let enabled = note.userInfo?["enabled"] as? Bool else { return }
                self?.adoptScratchpadPreference(enabled)
            }
        templateObserver = NotificationCenter.default.publisher(for: SettingsStore.configurationDidChange, object: store)
            .sink { [weak self] _ in self?.refreshTemplates() }
        refreshHistory()
    }

    func adoptAudioImportSettings(_ saved: Settings) {
        guard !hasPendingSettingsSave else { return }
        loading = true
        settings = saved; settingsBase = saved
        words = saved.dictionary.map { WordRow(text: $0) }
        snippets = saved.snippets.map { SnippetRow(trigger: $0.key, expansion: $0.value) }
        replacements = saved.replacements.map { ReplacementRow(source: $0.source, replacement: $0.replacement) }
        loadError = nil
        loading = false
    }

    var modelInstalled: Bool { FileManager.default.fileExists(atPath: modelPath) }

    var modelPath: String {
        settings.whisperModelPath ?? WhisperTranscriber.defaultModelPath()
    }

    func isSelected(_ model: ModelCatalog.Model) -> Bool {
        ModelCatalog.path(for: model) == modelPath
    }

    /// Point Parla at an already-downloaded model. The debounced save fires
    /// AppDelegate's onSaved, which reloads the context when the path changed.
    func selectModel(_ model: ModelCatalog.Model) {
        modelSelectionEpoch = UUID()
        settings.whisperModelPath = ModelCatalog.path(for: model)
    }

    /// Re-read everything from disk — called when the window opens/becomes key
    /// so external edits (settings file, new dictations) show up.
    func refresh() {
        refreshOriginalCopy()
        // Becoming key must not clobber a pending edit: flush any debounced
        // save before re-reading from disk, or the reload below discards it.
        flushPendingSave()
        loading = true
        defer { loading = false }
        importPreview = nil
        credentialMessage = store.migrateSelectedCredentials()
        settings = store.load()
        if !settings.energyActivityShadowEnabled { onActivityShadowRevoked() }
        settingsBase = settings
        surroundingPolicy = store.currentSurroundingTextPolicy(); surroundingReview = nil
        failoverBackups = settings.cleanupFailover?.backups ?? []; failoverReview = nil
        if store.lastError == nil { onPreparationSaved(settings) }
        else { onPreparationSaveFailed() }
        credentialDraft = ""
        refreshCredentialStatus()
        loadError = store.lastError
        onCanceledCaptureConfigurationChanged(loadError == nil)
        // Valid disk state replaces the failed edit; there is no pending save to retry.
        if loadError == nil { saveError = nil }
        reloadParakeetConfiguration()
        recordings.configure(settings: settings, error: loadError, now: recoveryClock())
        refreshRecoveryProjection()
        words = settings.dictionary.map { WordRow(text: $0) }
        snippets = settings.snippets.sorted { $0.key < $1.key }
            .map { SnippetRow(trigger: $0.key, expansion: $0.value) }
        replacements = settings.replacements.map { ReplacementRow(source: $0.source, replacement: $0.replacement) }
        if loadError == nil { history.reload(countLimit: settings.historyTextCount) }
        refreshHistory()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshPermissions()
    }

    /// Write a debounced edit now, so whatever the caller does to
    /// settings.json next lands after it instead of underneath it.
    func flushPendingSave() {
        guard saveItem != nil else { return }
        saveItem?.cancel()
        saveItem = nil
        save()
    }

    /// A finished download switched models behind the Hub's back. Only the
    /// path is taken, not a full refresh(): that rebuilds the dictionary and
    /// snippet rows, which drops focus from a field being typed in.
    func adoptModelPath(_ path: String) {
        loading = true
        defer { loading = false }
        settings.whisperModelPath = path
        settingsBase.whisperModelPath = path
    }

    /// Adopt only the passive authoritative field; preserve drafts and privacy bases.
    func adoptScratchpadPreference(_ enabled: Bool) {
        let wasLoading = loading; loading = true
        settings.scratchpadDictionaryAlternativesEnabled = enabled
        settingsBase.scratchpadDictionaryAlternativesEnabled = enabled
        loading = wasLoading
    }

    func refreshPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        axGranted = AXIsProcessTrusted()
    }

    /// The system prompt only ever appears once, so anything past `notDetermined`
    /// has to fall through to System Settings or the button does nothing.
    // Permission evidence/request are separate bottoms; a delayed grant changes only evidence.
    var microphoneAuthorization: () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) }
    var microphoneRequest: (@escaping (Bool) -> Void) -> Void = { AVCaptureDevice.requestAccess(for: .audio, completionHandler: $0) }
    lazy var microphonePrivacy: () -> Void = { [weak self] in self?.openPrivacyPane("Privacy_Microphone") }
    func requestMicrophone() {
        templates.cancel("Form canceled. Start again after allowing the microphone.")
        guard microphoneAuthorization() == .notDetermined else {
            microphonePrivacy()
            return
        }
        microphoneRequest { [weak self] ok in
            DispatchQueue.main.async { self?.micGranted = ok }
        }
    }

    func toggleLaunchAtLogin() {
        // Same logic as the menu toggle; fails harmlessly outside a bundled app.
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch { NSLog("%@", "Parla: launch-at-login toggle failed: \(error)") }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Take a recorded chord only if the whole set stays usable. Refusing here
    /// is the guard against binding Parla into a corner — a push-to-talk that
    /// can't be held, a chord the tap can never see, two bindings on one key.
    func setHotkey(_ path: WritableKeyPath<HotkeyBindings, KeyChord>, to chord: KeyChord) {
        var next = settings.hotkeys
        next[keyPath: path] = chord
        if next.problem() != nil {
            hotkeyRefusal = (next, chord)
            refreshHotkeyError()
            return
        }
        hotkeyError = nil
        settings.hotkeys = next
    }

    func setOptionalHotkey(_ path: WritableKeyPath<HotkeyBindings, KeyChord?>, to chord: KeyChord?) {
        guard loadError == nil else { return }
        var next = settings.hotkeys
        next[keyPath: path] = chord
        if next.problem() != nil {
            hotkeyRefusal = (next, chord)
            refreshHotkeyError()
            return
        }
        hotkeyError = nil
        settings.hotkeys = next
    }

    @discardableResult
    func savePreset(_ preset: TransformPreset, replacing id: UUID? = nil) -> Bool {
        guard loadError == nil else { return false }
        if let error = preset.validationError { presetError = error; return false }
        var next = settings.transformPresets
        if let id {
            guard let index = next.firstIndex(where: { $0.id == id }), id == preset.id else {
                presetError = "Preset changed. Reopen the editor."; return false
            }
            next[index] = preset
        } else {
            guard !next.contains(where: { $0.id == preset.id }) else { presetError = "This preset already exists."; return false }
            next.append(preset)
        }
        guard Set(next.map(\.id)).count == next.count else { presetError = "This preset already exists."; return false }
        presetError = nil
        settings.transformPresets = next
        return true
    }

    func selectPreset(_ id: UUID?) {
        guard loadError == nil else { return }
        if let id {
            var candidate = settings; candidate.selectedPresetID = id
            do { _ = try candidate.selectedTransformPreset() }
            catch { presetError = String(describing: error); return }
        }
        presetError = nil
        settings.selectedPresetID = id
    }

    func deletePreset(_ id: UUID) {
        guard loadError == nil else { return }
        settings.transformPresets.removeAll { $0.id == id }
        // Keep a missing selection visible and refuse it; never select a neighbor.
        presetError = nil
    }

    var selectedPresetError: String? {
        do { _ = try settings.selectedTransformPreset(); return nil }
        catch { return String(describing: error) }
    }

    func refreshHistory() {
        historyEntries = history.entries
        pendingHistory = history.pendingEntries
        historyError = history.lastError
        for (id, var preview) in historyRetries where !preview.saved {
            if !history.matches(preview.original, version: preview.version) {
                preview.stale = true
                historyRetries[id] = preview
            }
        }
    }

    func reloadHistory() {
        let current = store.load()
        history.reload(countLimit: store.lastError == nil ? current.historyTextCount : nil)
    }
    func clearHistory() { HistoryClearAction.run(invalidateResult: onHistoryCleared, clearHistory: { history.clear() }) }
    func deleteHistory(_ id: UUID) { history.delete(id) }
    func retryHistorySave(_ id: UUID) { history.retrySave(id) }
    func discardHistory(_ id: UUID) { history.discard(id) }
    func retryHistoryTrim() {
        let current = store.load()
        if let count = store.lastError == nil ? current.historyTextCount : history.countLimit {
            history.applyCountLimit(count)
        }
    }
    func copyOriginal(_ entry: HistoryEntry) { copy(entry.raw) }
    func copyResult(_ entry: HistoryEntry) { copy(entry.best) }

    func filteredHistory(_ query: String) -> [HistoryEntry] {
        historyEntries.filter { query.isEmpty || $0.raw.localizedCaseInsensitiveContains(query)
            || ($0.cleaned?.localizedCaseInsensitiveContains(query) ?? false)
            || ($0.appName?.localizedCaseInsensitiveContains(query) ?? false) }
    }

    /// The ONLY pasteboard write in the app — an explicit, user-initiated Copy.
    /// Parla itself never touches the clipboard anywhere else.
    func copy(_ text: String) {
        if let clipboard { clipboard(text); return }
        Self.writeExplicitCopy(text)
    }

    static func writeExplicitCopy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func openPrivacyPane(_ pane: String) {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    func recordProfileWinners(_ session: DictationSession.Session) {
        lastRecognitionProfile = session.recognitionProfileName
        lastOutputProfile = session.output?.name ?? "Global settings"
    }

    func profilePreview(bundleID: String, browserURL: String) -> ProfileResolution {
        ProfileResolver.resolve(settings, at: ProfileDestination(bundleID: bundleID, browserURL: browserURL))
    }

    @discardableResult
    func saveProfile(_ profile: DictationProfile, replacing index: Int? = nil) -> Bool {
        guard loadError == nil else { return false }
        if let error = profile.validationError { profileError = error; return false }
        if profile.enabled, (profile.recognitionEngine ?? settings.recognitionEngine) == .whisper, let path = profile.whisperModelPath {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue else {
                profileError = "Model file not found. Choose another or use the global model."
                return false
            }
        }
        var next = settings.profiles
        if let index {
            guard next.indices.contains(index), next[index].id == profile.id else { profileError = "Profile changed. Reopen the editor."; return false }
            next[index] = profile
        } else { next.append(profile) }
        let warnings = ProfileResolver.warnings(next)
        guard warnings.isEmpty else { profileError = warnings.joined(separator: "\n"); return false }
        profileError = nil
        settings.profiles = next
        return true
    }

    func deleteProfile(at index: Int) {
        guard loadError == nil, settings.profiles.indices.contains(index) else { return }
        settings.profiles.remove(at: index)
        profileError = nil
    }

    func moveProfile(at index: Int, by offset: Int) {
        guard loadError == nil, settings.profiles.indices.contains(index),
              settings.profiles.indices.contains(index + offset) else { return }
        settings.profiles.swapAt(index, index + offset)
    }

    func moveWord(_ id: UUID, by offset: Int) {
        guard let index = words.firstIndex(where: { $0.id == id }),
              words.indices.contains(index + offset) else { return }
        words.swapAt(index, index + offset)
    }

    func previewVocabulary(_ data: Data) {
        flushPendingSave()
        importPreview = nil
        guard loadError == nil, saveError == nil else {
            transferMessage = "Fix the settings error before importing."
            return
        }
        let current = store.load()
        loadError = store.lastError
        onCanceledCaptureConfigurationChanged(loadError == nil)
        guard loadError == nil else { return }
        do {
            importPreview = try VocabularyImportPreview(data: data, settings: current)
            transferMessage = nil
        } catch { transferMessage = error.localizedDescription }
    }

    func applyVocabulary(_ mode: VocabularyImportMode) {
        guard loadError == nil, saveError == nil, let preview = importPreview else {
            transferMessage = "Import expired. Choose the file again."
            return
        }
        do {
            let backup = try store.importVocabulary(preview, mode: mode)
            refresh()
            transferMessage = backup.map { "Imported. Backup saved to \($0.path)" } ?? "Added. Your existing entries were kept."
            onSaved()
        } catch {
            transferMessage = error.localizedDescription
            loadError = store.lastError
        onCanceledCaptureConfigurationChanged(loadError == nil)
        }
    }

    func chooseVocabularyImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: VocabularyDocument.maxFileBytes + 1) ?? Data()
            previewVocabulary(data)
        } catch { transferMessage = "Couldn't open the file: \(error.localizedDescription)" }
    }

    func exportVocabulary() {
        flushPendingSave()
        guard loadError == nil, saveError == nil else {
            transferMessage = "Fix the settings error before exporting."
            return
        }
        let current = store.load()
        loadError = store.lastError
        onCanceledCaptureConfigurationChanged(loadError == nil)
        guard loadError == nil else { return }
        do {
            let data = try VocabularyDocument(settings: current).encoded()
            guard let url = vocabularyExportPanel() else { return }
            try withValidatedExportDestination(url,fileExtension:"json") { try vocabularyExportWriter(data,url) }
            transferMessage = "Exported."
        } catch { transferMessage = "Couldn’t export. Choose another location and try again." }
    }

    /// Debounced whole-file save — same style as the menu's Set API Key path.
    private func touch(invalidateParakeet: Bool = true) {
        guard !loading, loadError == nil else { return }
        if invalidateParakeet { onParakeetDraftChanged() }
        importPreview = nil
        saveItem?.cancel()
        // Cleared as it fires: a non-nil saveItem has to mean "an edit is still
        // unsaved". Left set, the next flush replayed this save over anything
        // written to settings.json since.
        let item = DispatchWorkItem { [weak self] in
            self?.saveItem = nil
            self?.save()
        }
        saveItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private func save() {
        // A save scheduled while the file was valid must never fire after the
        // file has since been found invalid — never overwrite a file the user
        // is hand-fixing.
        guard loadError == nil else { return }
        let current = store.load()
        guard store.lastError == nil else {
            loadError = store.lastError
        onCanceledCaptureConfigurationChanged(loadError == nil)
            saveError = "Couldn’t save settings because settings.json can’t be read. Fix it, then try again."
            clearLastOriginal()
            onCanceledCaptureConfigurationChanged(false)
            recordings.configure(settings: current, error: store.lastError, now: recoveryClock())
            refreshRecoveryProjection()
            return
        }
        var s = settings
        s.dictionary = words.map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        s.snippets = Dictionary(
            snippets.map { ($0.trigger.trimmingCharacters(in: .whitespaces), $0.expansion) }
                .filter { !$0.0.isEmpty },
            uniquingKeysWith: { _, b in b })
        s.replacements = replacements.filter { !$0.source.isEmpty }
            .map { LiteralReplacement(source: $0.source, replacement: $0.replacement) }
        guard !s.dictionary.contains(where: {
            VocabularyHints.normalized($0).utf8.count > VocabularyHints.maxHintBytes && !settings.dictionary.contains($0)
        }) else {
            onCanceledCaptureConfigurationChanged(false)
            saveError = "A dictionary word is too long. Shorten it to save."
            return
        }
        guard s.replacements.allSatisfy({ $0.source.utf8.count <= VocabularyHints.maxHintBytes
            && $0.replacement.utf8.count <= VocabularyDocument.maxTextBytes }) else {
            onCanceledCaptureConfigurationChanged(false)
            saveError = "A replacement is too long. Shorten it to save."
            return
        }
        var oldWithoutShadow = current; oldWithoutShadow.energyActivityShadowEnabled = false
        var newWithoutShadow = s; newWithoutShadow.energyActivityShadowEnabled = false
        let shadowOnlySave = activityShadowDraftTouched && oldWithoutShadow == newWithoutShadow
        do {
            try onPreparationBeforeSave(s)
            if s.nativePreparationSafeStartEnabled, let generation = requestedPreparationConsent, preparedConsent != generation {
                try onPreparationConsent(generation)
                preparedConsent = generation
            }
            // The full writer preserves the fresh flag under its own lock;
            // spelling-action input limits do not restrict ordinary Hub edits.
            s = try store.savePreservingTemplates(s, replacing: settingsBase)
            templateDocument = s.guidedTemplates
            loading = true
            settings = s
            settingsBase = s
            loading = false
            saveError = nil
            requestedPreparationConsent = nil; preparedConsent = nil
            activityShadowDraftTouched = false
            if !shadowOnlySave { reloadParakeetConfiguration(); onPreparationSaved(s) }
            history.applyCountLimit(s.historyTextCount)
            recordings.configure(settings: s, error: nil, now: recoveryClock())
            refreshRecoveryProjection()
            // Compare net saved values: these passive choices (including a
            // coalesced revert) must not enter mic/model/credential setup.
            refreshOriginalCopy()
            onCanceledCaptureConfigurationChanged(true)
            var oldGeneral = current; oldGeneral.mouseBinding = nil
            var newGeneral = s; newGeneral.mouseBinding = nil
            oldGeneral.energyActivityShadowEnabled = false; newGeneral.energyActivityShadowEnabled = false
            oldGeneral.recognitionPreviewModelID = nil; newGeneral.recognitionPreviewModelID = nil
            oldGeneral.streamPreviewEnabled = false; newGeneral.streamPreviewEnabled = false
            oldGeneral.canceledCaptureUndoEnabled = false
            newGeneral.canceledCaptureUndoEnabled = false
            oldGeneral.clipboardReceiptRestoreEnabled = false
            newGeneral.clipboardReceiptRestoreEnabled = false
            oldGeneral.keepLastOriginalEnabled = false
            newGeneral.keepLastOriginalEnabled = false
            oldGeneral.nativePreparationSafeStartEnabled = false; newGeneral.nativePreparationSafeStartEnabled = false
            oldGeneral.nativePreparationConsent = nil; newGeneral.nativePreparationConsent = nil
            oldGeneral.scratchpadDictionaryAlternativesEnabled = false
            newGeneral.scratchpadDictionaryAlternativesEnabled = false
            if oldGeneral == newGeneral {
                onMouseBindingSaved()
            } else { onSaved() }
        } catch {
            onPreparationSaveFailed()
            if (error as? PreparationRefusal) == .busy { onPreparationSaveDeferred() }
            onCanceledCaptureConfigurationChanged(false)
            saveError = (error as? PreparationRefusal)?.description ?? "Couldn't save settings: \(error.localizedDescription)"
        }
    }
}

/// App-owned lazy Hub references only. Input-source observation belongs to the
/// one ShortcutLabels, and tap updates never evaluate an AppDelegate lazy getter.
final class HubBootstrapState {
    let shortcutLabels: ShortcutLabels
    private(set) var existingHub: HubModel?
    private(set) var tapStatus = InputTapStatus.unavailable
    init(shortcutLabels: ShortcutLabels = ShortcutLabels()) { self.shortcutLabels = shortcutLabels }
    func resolve(_ create: () -> HubModel) -> HubModel {
        if let existingHub { return existingHub }
        let hub = create(); attach(hub); return hub
    }
    func attach(_ hub: HubModel) {
        precondition(hub.shortcutLabels === shortcutLabels)
        existingHub = hub; hub.inputTapStatus = tapStatus
    }
    func updateTapStatus(_ value: InputTapStatus) {
        tapStatus = value; existingHub?.inputTapStatus = value
    }
}
