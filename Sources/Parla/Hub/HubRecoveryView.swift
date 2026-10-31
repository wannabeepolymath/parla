import SwiftUI
import ParlaCore

struct HubRecoveryView: View {
    @ObservedObject var model: HubModel
    @State private var confirmClear = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HubSection("Recovery audio", footer: "Off stops NEW disk stashes, including corpus collection. Existing files remain manageable and expire only when older than the lifetime; an exact-boundary file remains. Successful recognition deletes audio by default even if text Save fails. Secure purge takes priority. Text-count eviction and row deletion affect text only; no audio links are inferred.") {
                HubRow("Keep failed audio", detail: "Independent of text history; enabled by default") {
                    Toggle("", isOn: $model.settings.recoveryAudioEnabled).labelsHidden().toggleStyle(.switch)
                }
                HubDivider()
                HubRow("Audio lifetime", detail: "1–30 days; default 7. Applied at launch, refresh, stash and actions.") {
                    Stepper(value: $model.settings.recoveryAudioDays, in: RecordingStore.dayRange) {
                        Text("\(model.settings.recoveryAudioDays) days")
                    }.frame(width: 150)
                }
            }.disabled(model.loadError != nil)
            if model.recordings.keepAll {
                HubBanner(text: "PARLA_KEEP_RECORDINGS=1: while recovery audio is enabled, successful WAVs may be kept with .hyp.txt markers under the same lifetime. Marked successes are excluded below. Older files without markers cannot be classified reliably.")
            }
            if let status = model.recoveryPolicyStatus { HubBanner(text: status) }
            if let error = model.recoveryStoreError { HubBanner(text: "Last recording operation error: " + error) }
            if let message = model.recoveryMessage { Text(message).font(.caption).foregroundStyle(Theme.muted) }
            HubSection("Failed audio", footer: "Only inactive, regular local WAVs are actionable. Dates use file modification time for the existing expiry contract. Listing reads headers, not full audio. Historical app/site context is unknown: local transcription freezes CURRENT GLOBAL model, language and vocabulary. No insertion, selection access or cleanup/provider request runs.") {
                HStack {
                    Text("\(model.recordingSummary.count) inactive files · \(ByteCountFormatter.string(fromByteCount: Int64(model.recordingSummary.bytes), countStyle: .file))")
                    Spacer()
                    Button("Refresh") { model.refreshRecovery() }
                    Button("Clear…") { confirmClear = true }
                        .confirmationDialog("Delete inactive recording files and paired sidecars? Other active ownership is skipped.", isPresented: $confirmClear) {
                            Button("Delete inactive audio", role: .destructive) { model.clearRecovery() }
                        }
                }.font(.caption)
                if let id = model.playingRecordingID {
                    HStack { Text("Playing \(id)").font(.caption); Spacer(); Button("Stop") { model.stopRecoveryPlayback() } }
                    // Owned playback remains deletable explicitly even though active rows are excluded.
                    Button("Stop and delete playing recording", role: .destructive) {
                        model.deleteRecovery(model.recordingDirectory.appendingPathComponent(id))
                    }
                }
                ForEach(model.recoveryRows) { row in
                    HubDivider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.id).font(.caption.monospaced()).textSelection(.enabled)
                        Text(details(row)).font(.caption).foregroundStyle(Theme.muted)
                        if let reason = row.reason { Text(reason).font(.caption).foregroundStyle(Theme.muted) }
                        HStack {
                            Button("Play") { model.playRecovery(row.url) }.disabled(!row.available)
                            Button("Transcribe locally") { model.transcribeRecovery(row.url) }
                                .disabled(!row.available || model.loadError != nil || model.recoveryPreview?.loading == true)
                            Spacer()
                            Button("Delete", role: .destructive) { model.deleteRecovery(row.url) }
                        }.buttonStyle(HubButtonStyle())
                    }
                }
                if model.recoveryRows.isEmpty {
                    Text(model.recoveryStoreError == nil
                         ? "No inactive failed audio. Active files and marked corpus successes are excluded."
                         : "No rows available. File totals may be incomplete; check the recording error and Refresh.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
            }
            if let preview = model.recoveryPreview {
                HubSection("Local transcription preview") {
                    Text("Global model: \(URL(fileURLWithPath: preview.request.modelPath).lastPathComponent) · language: \(preview.request.language ?? "automatic") · \(preview.request.dictionary.count) vocabulary hints. Historical app/site context unknown.")
                        .font(.caption).foregroundStyle(Theme.muted)
                    if preview.loading { ProgressView("Waiting for local transcription…") }
                    if let error = preview.error { HubBanner(text: error) }
                    if let entry = preview.entry {
                        Text(entry.raw).textSelection(.enabled)
                        HStack {
                            Button("Copy") { model.copyRecovery() }
                            Button(preview.saveFailed ? "Retry Save" : "Save raw text") { model.saveRecovery() }.disabled(preview.saved)
                            if preview.saved { Text("Saved").font(.caption) }
                        }
                        Text("Save is explicit and disk-only. With history off, preview and Copy remain available until discard or quit. After Save, existing text retries can apply cleanup explicitly.").font(.caption).foregroundStyle(Theme.muted)
                    }
                    Button(preview.loading ? "Cancel transcription" : "Discard preview") { model.discardRecovery() }
                }
            }
        }
    }
    private func details(_ row: RecordingStore.Descriptor) -> String {
        let date = row.date?.formatted(date: .abbreviated, time: .shortened) ?? "Date unavailable"
        let expiry = row.expiry?.formatted(date: .abbreviated, time: .shortened) ?? "policy unavailable"
        let duration = row.duration.map { String(format: "%.1f seconds", $0) } ?? "duration unavailable"
        return "\(date) · expires \(expiry) · \(row.bytes) bytes · \(duration)"
    }
}
