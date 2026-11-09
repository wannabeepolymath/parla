import SwiftUI
import ParlaCore

struct HubRecoveryView: View {
    @ObservedObject var model: HubModel
    @State private var confirmClear = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HubSection("Failed dictations", footer: "If a dictation fails, Parla keeps its audio on this Mac so you can transcribe it again.") {
                HubRow("Keep audio from failed dictations") {
                    Toggle("", isOn: $model.settings.recoveryAudioEnabled).labelsHidden().toggleStyle(.switch)
                }
                HubDivider()
                HubRow("Delete after") {
                    Stepper(value: $model.settings.recoveryAudioDays, in: RecordingStore.dayRange) {
                        Text("\(model.settings.recoveryAudioDays) days")
                    }.frame(width: 150)
                }
            }.disabled(model.loadError != nil)
            if model.recordings.keepAll {
                HubBanner(text: "PARLA_KEEP_RECORDINGS is set, so successful recordings are kept too. They aren't listed below.")
            }
            if let status = model.recoveryPolicyStatus { HubBanner(text: status) }
            if let error = model.recoveryStoreError { HubBanner(text: "Audio error: " + error) }
            if let message = model.recoveryMessage { Text(message).font(.caption).foregroundStyle(Theme.muted) }
            HubSection("Saved audio", footer: "Transcribing uses your current model and language. Nothing is typed or sent online.") {
                HStack {
                    Text("\(model.recordingSummary.count) files · \(ByteCountFormatter.string(fromByteCount: Int64(model.recordingSummary.bytes), countStyle: .file))")
                    Spacer()
                    Button("Refresh") { model.refreshRecovery() }
                    Button("Clear…") { confirmClear = true }
                        .confirmationDialog("Delete all saved audio from failed dictations?", isPresented: $confirmClear) {
                            Button("Delete audio", role: .destructive) { model.clearRecovery() }
                        }
                }.font(.caption)
                if let id = model.playingRecordingID {
                    HStack { Text("Playing \(id)").font(.caption); Spacer(); Button("Stop") { model.stopRecoveryPlayback() } }
                    // Owned playback remains deletable explicitly even though active rows are excluded.
                    Button("Stop and delete", role: .destructive) {
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
                            Button("Transcribe") { model.transcribeRecovery(row.url) }
                                .disabled(!row.available || model.loadError != nil || model.recoveryPreview?.loading == true)
                            Spacer()
                            Button("Delete", role: .destructive) { model.deleteRecovery(row.url) }
                        }.buttonStyle(HubButtonStyle())
                    }
                }
                if model.recoveryRows.isEmpty {
                    Text(model.recoveryStoreError == nil
                         ? "No saved audio."
                         : "Couldn't list saved audio. Click Refresh to try again.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
            }
            if let preview = model.recoveryPreview {
                HubSection("Transcript") {
                    Text("Model: \(URL(fileURLWithPath: preview.request.modelPath).lastPathComponent) · Language: \(preview.request.language ?? "auto-detect")")
                        .font(.caption).foregroundStyle(Theme.muted)
                    if preview.loading { ProgressView("Transcribing…") }
                    if let error = preview.error { HubBanner(text: error) }
                    if let entry = preview.entry {
                        Text(entry.raw).textSelection(.enabled)
                        HStack {
                            Button("Copy") { model.copyRecovery() }
                            Button(preview.saveFailed ? "Try saving again" : "Save to history") { model.saveRecovery() }.disabled(preview.saved)
                            if preview.saved { Text("Saved").font(.caption) }
                        }
                    }
                    Button(preview.loading ? "Cancel" : "Discard") { model.discardRecovery() }
                }
            }
        }
    }
    private func details(_ row: RecordingStore.Descriptor) -> String {
        let date = row.date?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown date"
        let duration = row.duration.map { String(format: " · %.1f s", $0) } ?? ""
        let expiry = row.expiry.map { " · deleted " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
        return date + duration + expiry
    }
}
