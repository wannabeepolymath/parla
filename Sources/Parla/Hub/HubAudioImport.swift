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
        } catch { audioImport.invalidate("Fix settings.json, then try again.") }
    }
    private func audioImportSettings() -> Settings? {
        guard loadError == nil, saveError == nil else { audioImport.invalidate("Fix settings.json, then try again."); return nil }
        guard !hasPendingSettingsSave else { audioImport.notice("Wait for your settings to save, then try again."); return nil }
        guard let saved = try? store.savedRetrySnapshot(), !saved.recognitionConfigurationInvalid, RecognitionRequest(settings: saved).selection.engine != .invalid else {
            audioImport.invalidate("Choose a speech engine in General, then try again."); return nil
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
        savedAudioImport?.notice("Transcript closed. Saved files are kept until they expire.")
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
            audioImport.invalidate("Something changed. Choose the file again."); return false
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
            audioImport.notice("No timestamps for this file. Copy or save the text instead."); return
        }
        let data: Data
        do { data = try SubtitleExport.encoded(segments, format: format) }
        catch SubtitleExport.Refusal.markup {
            audioImport.notice("This text has characters SRT can’t show. Export WebVTT instead."); return
        } catch { audioImport.notice("This text can’t be exported as \(formatName). Copy or save it instead."); return }
        // Freeze bytes AND authority before the reentrant modal boundary.
        let job = review.job, resultID = review.entry.id
        guard let url = audioImportExportPanel("Parla-transcript.\(fileExtension)") else { return }
        guard audioImportExportIsCurrent(job: job, resultID: resultID) else { return }
        do {
            let written = try withValidatedExportDestination(url,fileExtension:fileExtension,protectedFiles:[job.source.originalURL]) {
                guard audioImportExportIsCurrent(job:job,resultID:resultID) else { return false }
                try historyExportWriter(data,url); return true
            }
            guard written else { return }
            audioImport.notice("Exported as \(formatName).")
        } catch HistoryExportDestination.Refusal.savedStorage {
            audioImport.notice("Couldn’t export because storage isn’t available. Try again.")
        } catch HistoryExportDestination.Refusal.protectedPath {
            audioImport.notice("Choose a different file name or folder.")
        } catch HistoryExportDestination.Refusal.extensionMismatch {
            audioImport.notice("Choose a filename ending in .\(fileExtension).")
        } catch {
            audioImport.notice("Couldn’t export. Choose another location and try again.")
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
    func cancelSavedAudioImport() { savedAudioImport?.invalidate("Transcription canceled. The saved file is kept.") }
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
            saved.notice("Text exported.")
        } catch HistoryExportDestination.Refusal.savedStorage {
            saved.notice("Couldn’t export because storage isn’t available. Try again.")
        } catch HistoryExportDestination.Refusal.protectedPath {
            saved.notice("Choose a different file name or folder.")
        } catch HistoryExportDestination.Refusal.extensionMismatch {
            saved.notice("Choose a filename ending in .txt.")
        } catch { saved.notice("Couldn’t export. Choose another location and try again.") }
    }
    static func selectAudioImportExportURL(_ filename: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: URL(fileURLWithPath: filename).pathExtension) ?? .plainText]
        panel.nameFieldStringValue = filename; panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
    static func selectAudioImportURL() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose an audio file"
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.wav, .quickTimeMovie]; panel.resolvesAliases = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
