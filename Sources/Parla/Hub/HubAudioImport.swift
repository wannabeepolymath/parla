import AppKit
import ParlaCore
import UniformTypeIdentifiers

extension HubModel {
    /// Rendering/selection refresh only: no flush, credential migration, setup,
    /// history reload, permission sampling, sample reads or model work.
    func refreshAudioImportConfiguration() {
        guard !hasPendingSettingsSave else { return }
        do {
            let saved = try store.savedRetrySnapshot()
            audioImport.observe(saved)
            adoptAudioImportSettings(saved)
        } catch { audioImport.invalidate("Repair saved settings before Start.") }
    }
    private func audioImportSettings() -> Settings? {
        guard loadError == nil, saveError == nil else { audioImport.invalidate("Repair and reload settings before Start, Copy or Save."); return nil }
        guard !hasPendingSettingsSave else { audioImport.notice("Save the pending settings draft before Start, Copy or Save."); return nil }
        guard let saved = try? store.savedRetrySnapshot(), !saved.recognitionConfigurationInvalid, RecognitionRequest(settings: saved).selection.engine != .invalid else {
            audioImport.invalidate("Repair saved recognition settings before Start."); return nil
        }
        audioImport.observe(saved)
        return saved
    }
    func chooseAudioImport() {
        guard !audioImport.busy else { return }
        if let url = audioImportPicker() { selectAudioImport(url) }
    }
    func selectAudioImport(_ url: URL) { audioImport.select(url) }
    func startAudioImport() {
        startAudioImport(mode: .raw)
    }
    func startTimedAudioImport() {
        startAudioImport(mode: .experimentalTimed)
    }
    private func startAudioImport(mode: AudioImportOwner.Mode) {
        guard audioImport.boundaryIsSafe(), let settings = audioImportSettings(),
              let job = audioImport.start(settings: settings, selectionEpoch: modelSelectionEpoch,
                  preparationEpoch: audioImportPreparationEpoch(), diagnostics: diagnostics, mode: mode) else { return }
        onAudioImport(job) { [weak self] result in
            guard let self else { job.revoke(); return }
            self.audioImport.observeSaved(self.store)
            self.audioImport.complete(job, result: result)
        }
    }
    func discardAudioImport() {
        audioImport.invalidate()
        savedAudioImport?.notice("Review closed. Committed private copies and results remain until expiry or Delete.")
    }
    func leaveAudioImport() { discardAudioImport() }
    func copyAudioImport() {
        audioImport.preparationChanged(audioImportPreparationEpoch())
        guard audioImport.boundaryIsSafe(), audioImportSettings() != nil else { return }
        audioImport.copy(using: copy)
    }
    func saveAudioImport() {
        audioImport.preparationChanged(audioImportPreparationEpoch())
        guard audioImport.boundaryIsSafe(), let settings = audioImportSettings() else { return }
        audioImport.save(settings: settings, history: history)
    }
    private func audioImportExportIsCurrent(job: AudioImportOwner.Job, resultID: UUID) -> Bool {
        guard audioImport.job === job, job.current, let review = audioImport.review,
              review.job === job, review.entry.id == resultID else { return false }
        audioImport.preparationChanged(audioImportPreparationEpoch())
        guard audioImport.boundaryIsSafe() else { return false }
        guard !hasPendingSettingsSave, modelSelectionEpoch == job.selectionEpoch,
              audioImportSettings() != nil, job.authorize(store) else {
            audioImport.invalidate("Export authority changed. Choose the file again."); return false
        }
        return job.current && audioImport.review?.entry.id == resultID
    }
    func exportAudioImportVTT() { exportAudioImport(.webVTT) }
    func exportAudioImportSRT() { exportAudioImport(.srt) }
    private func exportAudioImport(_ format: SubtitleExport.Format) {
        let fileExtension = format == .srt ? "srt" : "vtt"
        let formatName = format == .srt ? "SRT" : "WebVTT"
        guard let review = audioImport.review,
              audioImportExportIsCurrent(job: review.job, resultID: review.entry.id) else { return }
        guard let segments = review.segments else {
            audioImport.notice("Native timing is unavailable for this review. Copy or save its raw text."); return
        }
        let data: Data
        do { data = try SubtitleExport.encoded(segments, format: format) }
        catch SubtitleExport.Refusal.markup {
            audioImport.notice("SRT can’t show this text literally: it contains < > { } \\ or a code like &amp; that some players treat as formatting. Export WebVTT instead, or copy or save the raw text."); return
        } catch { audioImport.notice("These native segments cannot be exported as literal \(formatName). Copy or save the raw text."); return }
        // Freeze bytes AND authority before the reentrant modal boundary.
        let job = review.job, resultID = review.entry.id
        guard let url = audioImportExportPanel("Parla-native-segments.\(fileExtension)") else { return }
        guard audioImportExportIsCurrent(job: job, resultID: resultID) else { return }
        do {
            let written = try withValidatedExportDestination(url,fileExtension:fileExtension,protectedFiles:[job.source.originalURL]) {
                guard audioImportExportIsCurrent(job:job,resultID:resultID) else { return false }
                try historyExportWriter(data,url); return true
            }
            guard written else { return }
            audioImport.notice("Exported current native segments as \(formatName). History still contains text only.")
        } catch HistoryExportDestination.Refusal.savedStorage {
            audioImport.notice("Saved storage cannot supply complete protection. Retry export after storage is available.")
        } catch HistoryExportDestination.Refusal.protectedPath {
            audioImport.notice("Choose a file outside the original audio and Parla’s settings, history and recordings.")
        } catch HistoryExportDestination.Refusal.extensionMismatch {
            audioImport.notice("Choose a filename ending in .\(fileExtension).")
        } catch {
            audioImport.notice("Couldn’t export. Choose a writable location and explicitly try again; this review is still available.")
        }
    }

    func keepAudioImportAndTranscribe() {
        guard audioImport.boundaryIsSafe(), let settings = audioImportSettings(), let saved = savedAudioImport,
              saved.metadataReadiness == .ready, !saved.busy, !saved.ioBusy, let source = audioImport.takeSourceForSaved() else { return }
        saved.start(source:source,settings:settings,epoch:modelSelectionEpoch,preparation:audioImportPreparationEpoch(),diagnostics:diagnostics)
    }
    func refreshSavedAudioImports() { savedAudioImport?.refresh() }
    func openSavedAudioImport(_ id: UUID) {
        guard audioImport.boundaryIsSafe(), let settings = audioImportSettings() else { return }
        savedAudioImport?.open(id,settings:settings,epoch:modelSelectionEpoch,preparation:audioImportPreparationEpoch())
    }
    func retrySavedAudioImport(_ id: UUID) {
        guard audioImport.boundaryIsSafe(), let settings = audioImportSettings() else { return }
        savedAudioImport?.start(source:nil,id:id,settings:settings,epoch:modelSelectionEpoch,preparation:audioImportPreparationEpoch(),diagnostics:diagnostics)
    }
    func cancelSavedAudioImport() { savedAudioImport?.invalidate("Transcription canceled. Committed private files remain.") }
    func deleteSavedAudioImport(_ id: UUID) { savedAudioImport?.delete(id) }
    private func savedReviewIsCurrent(_ review: SavedAudioImportOwner.Review, allowIO: Bool = false) -> Bool {
        guard audioImport.boundaryIsSafe(), audioImportSettings() != nil else { return false }
        return savedAudioImport?.isCurrent(review,settings:store,epoch:modelSelectionEpoch,preparation:audioImportPreparationEpoch(),allowIO:allowIO) == true
    }
    func copySavedAudioImport() {
        guard let review = savedAudioImport?.review, savedReviewIsCurrent(review) else { return }
        copy(review.text)
    }
    func retrySaveAudioImportResult() {
        guard let review = savedAudioImport?.review, savedReviewIsCurrent(review) else { return }
        savedAudioImport?.retrySaveResult(review)
    }
    func saveSavedAudioImportHistory() {
        guard let review = savedAudioImport?.review, savedReviewIsCurrent(review), let settings = audioImportSettings() else { return }
        savedAudioImport?.saveHistory(review,settings:settings,history:history,currentSettings:{[weak self] in self?.audioImportSettings()},authorized:{[weak self] in self?.savedReviewIsCurrent(review,allowIO:true) == true})
    }
    func exportSavedAudioImportText() {
        guard let saved = savedAudioImport, let review = saved.review, savedReviewIsCurrent(review) else { return }
        let bytes = review.bytes // freeze bytes and independent review authority before panel
        guard let destination = audioImportExportPanel("Parla-saved-transcript.txt") else { return }
        guard savedReviewIsCurrent(review) else { return }
        do {
            let written = try withValidatedExportDestination(destination,fileExtension:"txt") {
                guard let io = saved.beginOutputIO(review) else { return false }
                defer { saved.endOutputIO(io) }
                guard savedReviewIsCurrent(review,allowIO:true) else { return false }
                try historyExportWriter(bytes,destination); return true
            }
            guard written else { return }
            saved.notice("Raw text exported. The saved job and independent History are unchanged.")
        } catch HistoryExportDestination.Refusal.savedStorage {
            saved.notice("Saved storage cannot supply complete protection. Retry export after storage is available.")
        } catch HistoryExportDestination.Refusal.protectedPath {
            saved.notice("Choose a destination outside the original audio and protected Parla files.")
        } catch HistoryExportDestination.Refusal.extensionMismatch {
            saved.notice("Choose a filename ending in .txt.")
        } catch { saved.notice("Couldn’t export. Retry export writes this same current raw text without transcription.") }
    }
    static func selectAudioImportExportURL(_ filename: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: URL(fileURLWithPath: filename).pathExtension) ?? .plainText]
        panel.nameFieldStringValue = filename; panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
    static func selectAudioImportURL() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose WAV or restricted MOV…"
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.wav, .quickTimeMovie]; panel.resolvesAliases = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
