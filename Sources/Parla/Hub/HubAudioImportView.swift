import SwiftUI
import ParlaCore

struct HubAudioImportView: View {
    @ObservedObject var model: HubModel
    @ObservedObject var owner: AudioImportOwner
    @State private var timestamps = false
    @State private var dropTargeted = false

    private var settingsBlocked: Bool { model.hasPendingSettingsSave || model.loadError != nil || model.saveError != nil }
    private var languageName: String {
        guard let code = model.settings.language, !code.isEmpty else { return "Auto-detect" }
        return WhisperTranscriber.languages.first { $0.code == code }?.name ?? code
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HubLayout.sectionSpacing) {
            if let source = owner.source {
                HubSection("File") {
                    HubRow(source.displayName, detail: ByteCountFormatter.string(fromByteCount: Int64(source.byteCount), countStyle: .file)) {
                        HStack(spacing: 8) {
                            Button("Remove", action: model.discardAudioImport).buttonStyle(HubButtonStyle())
                            Button("Choose Another…", action: model.chooseAudioImport).buttonStyle(HubButtonStyle()).disabled(owner.busy)
                        }
                    }
                    HubDivider()
                    HubRow("Language", detail: "Uses the language from General") {
                        HStack(spacing: 8) {
                            HubValue(languageName)
                            Button("Change…") { model.requestedPage = .general }.buttonStyle(HubButtonStyle())
                        }
                    }
                    HubDivider()
                    HubToggleRow("Include timestamps",
                                 detail: source.format == .mov ? "Not available for MOV files" : "Needs Whisper, a 16 kHz WAV and a chosen language",
                                 isOn: $timestamps)
                        .disabled(source.format == .mov)
                    HubDivider()
                    HStack {
                        Spacer()
                        Button("Transcribe") {
                            if timestamps && source.format != .mov { model.startTimedAudioImport() } else { model.startAudioImport() }
                        }
                        .buttonStyle(HubButtonStyle(kind: .primary))
                        .disabled(owner.busy || settingsBlocked)
                    }
                    .hubInset()
                }
            } else {
                dropZone
            }
            if owner.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(owner.message ?? "Working…").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Spacer()
                    Button("Cancel", action: model.discardAudioImport).buttonStyle(HubButtonStyle())
                }
            } else if let message = owner.message {
                HubNote(message)
            }
            if let review = owner.review { reviewSection(review) }
            if let saved = model.savedAudioImport { SavedAudioImportView(model: model, owner: saved) }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(dropTargeted ? Theme.accent : Theme.muted)
                .accessibilityHidden(true)
            Text("Drop an audio file here")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
            Button("Choose File…", action: model.chooseAudioImport)
                .buttonStyle(HubButtonStyle())
                .disabled(owner.busy)
            Text("WAV, M4A, MP3 or MOV · up to 10 minutes and 20 MB")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(RoundedRectangle(cornerRadius: 10).fill(dropTargeted ? Theme.accentFill.opacity(0.4) : Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(dropTargeted ? Theme.accent : Theme.control, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, !owner.busy else { return false }
            model.selectAudioImport(url)
            return true
        } isTargeted: { dropTargeted = $0 }
        .help("MOV files need uncompressed 16 kHz mono audio. WAV files should be mono 16-bit.")
    }

    private func reviewSection(_ review: AudioImportOwner.Review) -> some View {
        HubSection("Transcript", footer: review.segments != nil ? "Timestamps are approximate and are lost when you close this transcript." : nil) {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    Text(verbatim: review.entry.raw)
                        .font(.system(size: 13)).foregroundStyle(Theme.text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 80, maxHeight: 320)
                if let segments = review.segments {
                    Divider()
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(segments.cues.enumerated()), id: \.offset) { _, cue in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\((try? SubtitleExport.timestamp(tick: cue.start)) ?? "–") → \((try? SubtitleExport.timestamp(tick: cue.end)) ?? "–")")
                                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.muted)
                                    Text(verbatim: cue.text).font(.system(size: 13)).foregroundStyle(Theme.text)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 240)
                }
                HStack(spacing: 8) {
                    Button("Close", action: model.discardAudioImport).buttonStyle(HubButtonStyle())
                    Spacer()
                    if review.saved { Text("Saved to History").font(.system(size: 12)).foregroundStyle(Theme.muted) }
                    else if !model.settings.historyEnabled { Text("History is off").font(.system(size: 12)).foregroundStyle(Theme.muted) }
                    Menu("Export") {
                        if review.segments != nil {
                            Button("WebVTT Subtitles…", action: model.exportAudioImportVTT)
                            Button("SRT Subtitles…", action: model.exportAudioImportSRT)
                        }
                        Button("JSON (transcript, model and timestamps)…", action: model.exportAudioImportJSON)
                    }
                    .menuStyle(.borderedButton).fixedSize()
                    Button("Copy", action: model.copyAudioImport).buttonStyle(HubButtonStyle())
                    if !review.saved && model.settings.historyEnabled {
                        Button(review.saveFailed ? "Try Saving Again" : "Save to History", action: model.saveAudioImport)
                            .buttonStyle(HubButtonStyle(kind: .primary))
                    }
                }
                .disabled(settingsBlocked)
            }
            .hubInset()
        }
    }
}


private struct SavedAudioImportView: View {
    @ObservedObject var model: HubModel
    @ObservedObject var owner: SavedAudioImportOwner
    private var settingsBlocked: Bool { model.hasPendingSettingsSave || model.loadError != nil || model.saveError != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: HubLayout.sectionSpacing) {
            HubSection("Saved files",
                       footer: owner.message ?? "Parla can keep a copy of a file (including any video) and its transcript on this Mac for 7 days, even with history off. Up to 10 files.",
                       accessory: {
                HubIconButton("arrow.clockwise", label: "Refresh saved files", action: model.refreshSavedAudioImports)
                    .disabled(owner.busy || owner.ioBusy)
            }) {
                HubRow("Keep a copy", detail: "Saves the chosen file, then transcribes it") {
                    HStack(spacing: 8) {
                        if owner.busy || owner.ioBusy { ProgressView().controlSize(.small) }
                        if owner.busy {
                            if let job = owner.job {
                                Button("Delete") { model.deleteSavedAudioImport(job.id) }.buttonStyle(HubButtonStyle(kind: .danger))
                            }
                            Button("Cancel", action: model.cancelSavedAudioImport).buttonStyle(HubButtonStyle())
                        } else {
                            Button("Save and Transcribe", action: model.keepAudioImportAndTranscribe)
                                .buttonStyle(HubButtonStyle())
                                .disabled(model.audioImport.source == nil || model.audioImport.busy || owner.ioBusy || settingsBlocked)
                        }
                    }
                }
                ForEach(owner.rows) { row in
                    HubDivider()
                    HubRow(row.label, detail: details(row)) {
                        HStack(spacing: 4) {
                            if row.result != nil {
                                Button("Open") { model.openSavedAudioImport(row.id) }
                                    .buttonStyle(HubButtonStyle())
                                    .disabled(row.deleting || owner.busy || owner.ioBusy)
                                    .padding(.trailing, 4)
                            }
                            HubMoreMenu {
                                Button("Transcribe Again") { model.retrySavedAudioImport(row.id) }
                                    .disabled(row.deleting || !row.sourceAvailable || owner.busy || owner.ioBusy || model.hasPendingSettingsSave)
                                Divider()
                                Button(row.deleting ? "Try Deleting Again" : "Delete", role: .destructive) { model.deleteSavedAudioImport(row.id) }
                            }
                        }
                    }
                }
            }
            if let review = owner.review {
                HubSection("Saved transcript", footer: "Transcribed with \(Self.engineName(review.observed.engine))") {
                    VStack(alignment: .leading, spacing: 12) {
                        ScrollView {
                            Text(verbatim: review.text).font(.system(size: 13)).foregroundStyle(Theme.text).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 80, maxHeight: 280)
                        HStack(spacing: 8) {
                            Spacer()
                            if review.accepted != nil, review.historySaved && !review.recordFailed {
                                Text("Saved to History").font(.system(size: 12)).foregroundStyle(Theme.muted)
                            } else if review.accepted != nil, !model.settings.historyEnabled {
                                Text("History is off").font(.system(size: 12)).foregroundStyle(Theme.muted)
                            }
                            Button("Export Text…", action: model.exportSavedAudioImportText).buttonStyle(HubButtonStyle())
                            Button("Copy", action: model.copySavedAudioImport).buttonStyle(HubButtonStyle())
                            if review.accepted == nil {
                                Button("Try Saving Again", action: model.retrySaveAudioImportResult)
                                    .buttonStyle(HubButtonStyle(kind: .primary)).disabled(owner.ioBusy)
                            } else if !(review.historySaved && !review.recordFailed), model.settings.historyEnabled {
                                Button(review.recordFailed || review.historyFailed ? "Try Saving Again" : review.associationUnknown ? "Check History" : "Save to History",
                                       action: model.saveSavedAudioImportHistory)
                                    .buttonStyle(HubButtonStyle(kind: .primary)).disabled(owner.ioBusy)
                            }
                        }
                        .disabled(settingsBlocked)
                    }
                    .hubInset()
                }
            }
        }
    }

    private func details(_ row: SavedAudioImportStore.Row) -> String {
        var parts = ["\(row.sourceProfile == .qtPCM16kV1 ? "MOV" : "WAV")",
                     "Saved \(row.created.formatted(date: .abbreviated, time: .shortened))",
                     "Deletes \(row.expires.formatted(date: .abbreviated, time: .omitted))",
                     row.deleting ? "Deleting…" : Self.status(row.state)]
        if !row.sourceAvailable { parts.append("Audio file missing") }
        return parts.joined(separator: " · ")
    }

    private static func status(_ state: SavedAudioImportStore.State) -> String {
        switch state {
        case .staging: return "Saving…"
        case .committed: return "Saved"
        case .queued: return "Waiting…"
        case .running: return "Transcribing…"
        case .failed: return "Transcription failed"
        case .canceled: return "Canceled"
        case .interrupted: return "Interrupted"
        case .deleting: return "Deleting…"
        }
    }
    private static func engineName(_ raw: String) -> String {
        switch RecognitionEngine(rawValue: raw) {
        case .whisper: return "Whisper"
        case .appleSpeech: return "Apple Speech"
        case .parakeet: return "Parakeet"
        default: return "an unknown engine"
        }
    }
}
