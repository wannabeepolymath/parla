import SwiftUI
import ParlaCore

struct HubAudioImportView: View {
    @ObservedObject var model: HubModel
    @ObservedObject var owner: AudioImportOwner
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose one locally resident WAV, then Start. Supported: mono signed 16-bit PCM RIFF at 8, 16, 22.05, 24, 32, 44.1 or 48 kHz, 0.4–600 seconds and up to 20 MiB. Both limits apply; higher rates may reach the byte limit sooner. Other formats need conversion outside Parla.")
            Text("Start uses saved global recognition settings. No microphone, target app, cleanup or automatic clipboard/history action.")
                .foregroundStyle(.secondary)
            Text(model.recognitionCapabilityDetail).font(.caption)
            Text("Saved language: \(model.settings.language ?? "Automatic") · Dictionary hints: \(model.settings.dictionary.count)")
                .font(.caption)
            HStack {
                Button("Choose WAV…", action: model.chooseAudioImport).disabled(owner.busy)
                Button("Start", action: model.startAudioImport)
                    .disabled(owner.source == nil || owner.busy || model.hasPendingSettingsSave || model.loadError != nil || model.saveError != nil)
                Button("Start with experimental timing", action: model.startTimedAudioImport)
                    .disabled(owner.source == nil || owner.busy || model.hasPendingSettingsSave || model.loadError != nil || model.saveError != nil)
                Button("Discard", action: model.discardAudioImport)
                    .disabled(owner.source == nil && owner.job == nil)
            }
            if let source = owner.source {
                Text(verbatim: "\(source.displayName) · \(source.byteCount) bytes").lineLimit(3)
            }
            if owner.busy { ProgressView("Running or stopping; waiting for actual exit.") }
            Text("Experimental timing: Whisper, original mono 16 kHz PCM WAV, and a selected language for multilingual models. Native segment estimates have no speaker attribution. Timing lasts only in this review; saved History keeps text only.")
                .font(.caption).foregroundStyle(.secondary)
            if let saved = model.savedAudioImport { SavedAudioImportView(model:model,owner:saved) }
            if let message = owner.message { Text(verbatim: message).font(.callout) }
            if let review = owner.review {
                Text("Raw review").font(.headline)
                Text("\(review.sourceInfo.container) · \(review.sourceInfo.encoding) · mono \(review.sourceInfo.sourceRate) Hz · \(review.sourceInfo.sourceFrames) source frames")
                    .font(.caption)
                Text(review.sourceInfo.origin == .strictPCM16k
                    ? "16 kHz PCM · \(review.sourceInfo.outputFrames) output frames"
                    : "Converted to 16 kHz · \(review.sourceInfo.outputFrames) output frames · \(review.sourceInfo.clippedSamples) clipped samples")
                    .font(.caption)
                ScrollView {
                    Text(verbatim: review.entry.raw)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 140, maxHeight: 320)
                if let segments = review.segments {
                    Text("Experimental native ranges · no speaker attribution").font(.headline)
                    Text("Cue text comes directly from the recognizer and can differ from the marker-filtered raw transcript. Gaps and overlaps are retained; accuracy and complete speech coverage are unqualified. Closing or discarding this review loses timing.")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(segments.cues.enumerated()), id: \.offset) { _, cue in
                                Text("\((try? SubtitleExport.timestamp(tick: cue.start)) ?? "Unavailable") → \((try? SubtitleExport.timestamp(tick: cue.end)) ?? "Unavailable")")
                                    .font(.caption.monospacedDigit())
                                Text(verbatim: cue.text)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 240)
                }
                HStack {
                    Button("Copy", action: model.copyAudioImport)
                    if review.segments != nil {
                        Button("Export native WebVTT…", action: model.exportAudioImportVTT)
                        Button("Export native SRT…", action: model.exportAudioImportSRT)
                    }
                    if review.saved { Text("Saved").foregroundStyle(.secondary) }
                    else if model.settings.historyEnabled {
                        Button(review.saveFailed ? "Retry Save" : "Save", action: model.saveAudioImport)
                    } else { Text("History is off; Copy is available.").foregroundStyle(.secondary) }
                }.disabled(model.hasPendingSettingsSave || model.loadError != nil || model.saveError != nil)
            }
        }
    }
}


private struct SavedAudioImportView: View {
    @ObservedObject var model: HubModel
    @ObservedObject var owner: SavedAudioImportOwner
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Divider()
            Text("Keep a private copy").font(.headline)
            Text("Keep this WAV and its raw result in Parla for seven days. History off does not prevent this copy. It expires after seven days and is removed when Parla can safely finish deletion. Cancel keeps committed files; Delete removes the saved job. Independent History text and exports remain.")
                .font(.callout)
            Text("Up to 10 saved jobs and 256 MiB including reserved writes. The WAV limit is 20 MiB; raw results are limited to 1 MiB. Saved transcription has no timing. Storage writes are checked; survival of device or power failure is unqualified.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Keep a private copy and transcribe",action:model.keepAudioImportAndTranscribe)
                    .disabled(model.audioImport.source == nil || model.audioImport.busy || owner.busy || owner.ioBusy || model.hasPendingSettingsSave || model.loadError != nil || model.saveError != nil)
                Button("Refresh saved jobs",action:model.refreshSavedAudioImports).disabled(owner.busy || owner.ioBusy)
                if owner.busy {
                    Button("Cancel transcription",action:model.cancelSavedAudioImport)
                    if let job = owner.job { Button("Delete current saved job",role:.destructive) { model.deleteSavedAudioImport(job.id) } }
                }
            }
            if owner.busy || owner.ioBusy { ProgressView("Waiting for saved work to finish.") }
            if let message = owner.message { Text(verbatim:message).font(.callout) }
            ForEach(owner.rows) { row in
                VStack(alignment:.leading,spacing:6) {
                    Text(verbatim:row.label).font(.headline)
                    Text("Created \(row.created.formatted()) · Expires \(row.expires.formatted()) · \(row.sourceBytes) bytes").font(.caption)
                    Text(row.deleting ? "Deletion pending; private files may remain." : "Latest attempt: \(row.state.rawValue)")
                        .font(.caption).foregroundStyle(.secondary)
                    if !row.sourceAvailable { Text("Source unavailable. A saved raw result can still be opened if it verifies.").font(.caption) }
                    if row.result != nil { Text("Saved raw result · Open to verify before review.").font(.caption) }
                    HStack {
                        if row.result != nil { Button("Open raw review") { model.openSavedAudioImport(row.id) }.disabled(row.deleting || owner.busy || owner.ioBusy) }
                        Button("Retry transcription") { model.retrySavedAudioImport(row.id) }
                            .disabled(row.deleting || !row.sourceAvailable || owner.busy || owner.ioBusy || model.hasPendingSettingsSave)
                        Button(row.deleting ? "Retry Delete" : "Delete saved job",role:.destructive) { model.deleteSavedAudioImport(row.id) }
                    }
                }.padding(.vertical,6)
            }
            if let review = owner.review {
                Text("Saved raw review").font(.headline)
                Text("Observed recognition: \(review.observed.engine). Stored identity is metadata, not model verification.")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView { Text(verbatim:review.text).frame(maxWidth:.infinity,alignment:.leading) }.frame(minHeight:100,maxHeight:280)
                HStack {
                    Button("Copy",action:model.copySavedAudioImport)
                    Button("Export text…",action:model.exportSavedAudioImportText)
                    if review.accepted == nil { Button("Retry Save result",action:model.retrySaveAudioImportResult).disabled(owner.ioBusy) }
                    else if review.historySaved && !review.recordFailed { Text("Saved to History").foregroundStyle(.secondary) }
                    else if model.settings.historyEnabled {
                        Button(review.recordFailed ? "Retry record status" : review.associationUnknown ? "Check History status" : review.historyFailed ? "Retry Save to History" : "Save to History",action:model.saveSavedAudioImportHistory)
                            .disabled(owner.ioBusy)
                    } else { Text("History is off.").foregroundStyle(.secondary) }
                }.disabled(model.hasPendingSettingsSave || model.loadError != nil || model.saveError != nil)
            }
        }
    }
}
