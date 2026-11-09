import SwiftUI
import ParlaCore

struct HubAudioImportView: View {
    @ObservedObject var model: HubModel
    @ObservedObject var owner: AudioImportOwner
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mono 16-bit WAV, or MOV with uncompressed 16 kHz mono audio. Up to 10 minutes and 20 MB.")
                .foregroundStyle(.secondary)
            Text("Language: \(model.settings.language ?? "auto-detect")")
                .font(.caption)
            HStack {
                Button("Choose file…", action: model.chooseAudioImport).disabled(owner.busy)
                Button("Transcribe", action: model.startAudioImport)
                    .disabled(owner.source == nil || owner.busy || model.hasPendingSettingsSave || model.loadError != nil || model.saveError != nil)
                Button("Transcribe with timestamps", action: model.startTimedAudioImport)
                    .disabled(owner.source == nil || owner.source?.format == .mov || owner.busy || model.hasPendingSettingsSave || model.loadError != nil || model.saveError != nil)
                Button("Discard", action: model.discardAudioImport)
                    .disabled(owner.source == nil && owner.job == nil)
            }
            if let source = owner.source {
                Text(verbatim: "\(source.displayName) · \(ByteCountFormatter.string(fromByteCount: Int64(source.byteCount), countStyle: .file))").lineLimit(3)
            }
            if owner.busy { ProgressView("Working…") }
            Text("Timestamps need Whisper, a 16 kHz WAV and a chosen language.")
                .font(.caption).foregroundStyle(.secondary)
            if let saved = model.savedAudioImport { SavedAudioImportView(model:model,owner:saved) }
            if let message = owner.message { Text(verbatim: message).font(.callout) }
            if let review = owner.review {
                Text("Transcript").font(.headline)
                ScrollView {
                    Text(verbatim: review.entry.raw)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 140, maxHeight: 320)
                if let segments = review.segments {
                    Text("Timestamps").font(.headline)
                    Text("Timestamps are approximate and are lost when you close this transcript.")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(segments.cues.enumerated()), id: \.offset) { _, cue in
                                Text("\((try? SubtitleExport.timestamp(tick: cue.start)) ?? "–") → \((try? SubtitleExport.timestamp(tick: cue.end)) ?? "–")")
                                    .font(.caption.monospacedDigit())
                                Text(verbatim: cue.text)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 240)
                }
                HStack {
                    Button("Copy", action: model.copyAudioImport)
                    if review.segments != nil {
                        Button("Export WebVTT…", action: model.exportAudioImportVTT)
                        Button("Export SRT…", action: model.exportAudioImportSRT)
                    }
                    if review.saved { Text("Saved").foregroundStyle(.secondary) }
                    else if model.settings.historyEnabled {
                        Button(review.saveFailed ? "Try saving again" : "Save to history", action: model.saveAudioImport)
                    } else { Text("History is off.").foregroundStyle(.secondary) }
                }.disabled(model.hasPendingSettingsSave || model.loadError != nil || model.saveError != nil)
            }
        }
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


private struct SavedAudioImportView: View {
    @ObservedObject var model: HubModel
    @ObservedObject var owner: SavedAudioImportOwner
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Divider()
            Text("Saved files").font(.headline)
            Text("Parla can keep a copy of the file (including any video) and its transcript on this Mac for 7 days, even with history off. Up to 10 files.")
                .font(.callout)
            HStack {
                Button("Save a copy and transcribe",action:model.keepAudioImportAndTranscribe)
                    .disabled(model.audioImport.source == nil || model.audioImport.busy || owner.busy || owner.ioBusy || model.hasPendingSettingsSave || model.loadError != nil || model.saveError != nil)
                Button("Refresh",action:model.refreshSavedAudioImports).disabled(owner.busy || owner.ioBusy)
                if owner.busy {
                    Button("Cancel",action:model.cancelSavedAudioImport)
                    if let job = owner.job { Button("Delete",role:.destructive) { model.deleteSavedAudioImport(job.id) } }
                }
            }
            if owner.busy || owner.ioBusy { ProgressView("Working…") }
            if let message = owner.message { Text(verbatim:message).font(.callout) }
            ForEach(owner.rows) { row in
                VStack(alignment:.leading,spacing:6) {
                    Text(verbatim:row.label).font(.headline)
                    Text("\(row.sourceProfile == .qtPCM16kV1 ? "MOV" : "WAV") · Saved \(row.created.formatted(date: .abbreviated, time: .shortened)) · Deleted \(row.expires.formatted(date: .abbreviated, time: .omitted))").font(.caption)
                    Text(row.deleting ? "Deleting…" : Self.status(row.state))
                        .font(.caption).foregroundStyle(.secondary)
                    if !row.sourceAvailable { Text("The audio file is missing.").font(.caption) }
                    HStack {
                        if row.result != nil { Button("Open transcript") { model.openSavedAudioImport(row.id) }.disabled(row.deleting || owner.busy || owner.ioBusy) }
                        Button("Transcribe again") { model.retrySavedAudioImport(row.id) }
                            .disabled(row.deleting || !row.sourceAvailable || owner.busy || owner.ioBusy || model.hasPendingSettingsSave)
                        Button(row.deleting ? "Try deleting again" : "Delete",role:.destructive) { model.deleteSavedAudioImport(row.id) }
                    }
                }.padding(.vertical,6)
            }
            if let review = owner.review {
                Text("Transcript").font(.headline)
                Text("Transcribed with \(Self.engineName(review.observed.engine))")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView { Text(verbatim:review.text).frame(maxWidth:.infinity,alignment:.leading) }.frame(minHeight:100,maxHeight:280)
                HStack {
                    Button("Copy",action:model.copySavedAudioImport)
                    Button("Export text…",action:model.exportSavedAudioImportText)
                    if review.accepted == nil { Button("Try saving again",action:model.retrySaveAudioImportResult).disabled(owner.ioBusy) }
                    else if review.historySaved && !review.recordFailed { Text("Saved to history").foregroundStyle(.secondary) }
                    else if model.settings.historyEnabled {
                        Button(review.recordFailed || review.historyFailed ? "Try saving again" : review.associationUnknown ? "Check history" : "Save to history",action:model.saveSavedAudioImportHistory)
                            .disabled(owner.ioBusy)
                    } else { Text("History is off.").foregroundStyle(.secondary) }
                }.disabled(model.hasPendingSettingsSave || model.loadError != nil || model.saveError != nil)
            }
        }
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
