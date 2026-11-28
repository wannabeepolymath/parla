import SwiftUI
import ParlaCore

struct HubRecoveryView: View {
    @ObservedObject var model: HubModel
    @State private var confirmClear = false

    private var summary: String {
        let count = model.recordingSummary.count
        guard count > 0 else { return "No saved audio" }
        return "\(count) file\(count == 1 ? "" : "s") · "
            + ByteCountFormatter.string(fromByteCount: Int64(model.recordingSummary.bytes), countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HubLayout.sectionSpacing) {
            HubSection("Failed dictations", footer: model.recoveryRows.isEmpty ? nil : "Transcribing uses your current model and language. Nothing is typed or sent online.") {
                HubToggleRow("Keep audio from failed dictations", detail: "So you can transcribe it again later",
                             isOn: $model.settings.recoveryAudioEnabled)
                    .disabled(model.loadError != nil)
                HubDivider()
                HubRow("Delete after") {
                    HStack(spacing: 6) {
                        Text("\(model.settings.recoveryAudioDays) days").monospacedDigit()
                            .font(.system(size: 13)).foregroundStyle(Theme.text)
                        Stepper("Delete after", value: $model.settings.recoveryAudioDays, in: RecordingStore.dayRange).labelsHidden()
                    }
                }
                .disabled(model.loadError != nil)
                HubDivider()
                HubRow("Saved audio", detail: model.recoveryStoreError == nil ? summary : "Couldn’t list saved audio") {
                    HStack(spacing: 8) {
                        if model.recoveryStoreError != nil {
                            Button("Try Again") { model.refreshRecovery() }.buttonStyle(HubButtonStyle())
                        }
                        Button("Clear…") { confirmClear = true }
                            .buttonStyle(HubButtonStyle(kind: .danger))
                            .disabled(model.recordingSummary.count == 0)
                            .confirmationDialog("Delete all saved audio from failed dictations?", isPresented: $confirmClear) {
                                Button("Delete Audio", role: .destructive) { model.clearRecovery() }
                            }
                    }
                }
                if let id = model.playingRecordingID {
                    HubDivider()
                    HubRow("Playing", detail: id) {
                        HStack(spacing: 8) {
                            // Owned playback remains deletable explicitly even though active rows are excluded.
                            Button("Stop and Delete") { model.deleteRecovery(model.recordingDirectory.appendingPathComponent(id)) }
                                .buttonStyle(HubButtonStyle(kind: .danger))
                            Button("Stop") { model.stopRecoveryPlayback() }.buttonStyle(HubButtonStyle())
                        }
                    }
                }
                ForEach(model.recoveryRows) { row in
                    HubDivider()
                    HubRow(row.date?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown date",
                           detail: details(row)) {
                        HStack(spacing: 4) {
                            HubIconButton("play.fill", label: "Play") { model.playRecovery(row.url) }.disabled(!row.available)
                            Button("Transcribe") { model.transcribeRecovery(row.url) }
                                .buttonStyle(HubButtonStyle())
                                .disabled(!row.available || model.loadError != nil || model.recoveryPreview?.loading == true)
                                .padding(.horizontal, 4)
                            HubIconButton("trash", label: "Delete audio") { model.deleteRecovery(row.url) }
                        }
                    }
                    .help(row.id)
                }
            }
            if model.recordings.keepAll {
                HubBanner(text: "PARLA_KEEP_RECORDINGS is set, so successful recordings are kept too. They aren’t listed here.", kind: .warning)
            }
            if let status = model.recoveryPolicyStatus { HubBanner(text: status, kind: .warning) }
            if let error = model.recoveryStoreError { HubBanner(text: "Saved audio error: " + error) }
            if let message = model.recoveryMessage { HubNote(message) }
            if let preview = model.recoveryPreview {
                HubSection("Transcript", footer: "Model: \(ModelCatalog.all.first { ModelCatalog.path(for: $0) == preview.request.modelPath }?.hubName ?? URL(fileURLWithPath: preview.request.modelPath).lastPathComponent) · Language: \(preview.request.language ?? "auto-detect")") {
                    VStack(alignment: .leading, spacing: 10) {
                        if preview.loading { ProgressView("Transcribing…").controlSize(.small) }
                        if let error = preview.error { HubBanner(text: error) }
                        if let entry = preview.entry {
                            Text(entry.raw).font(.system(size: 13)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack(spacing: 8) {
                            Button(preview.loading ? "Cancel" : "Discard") { model.discardRecovery() }.buttonStyle(HubButtonStyle())
                            Spacer()
                            if preview.entry != nil {
                                if preview.saved { Text("Saved to History").font(.system(size: 12)).foregroundStyle(Theme.muted) }
                                Button("Copy") { model.copyRecovery() }.buttonStyle(HubButtonStyle())
                                Button(preview.saveFailed ? "Try Saving Again" : "Save to History") { model.saveRecovery() }
                                    .buttonStyle(HubButtonStyle(kind: .primary)).disabled(preview.saved)
                            }
                        }
                    }
                    .hubInset()
                }
            }
        }
    }

    private func details(_ row: RecordingStore.Descriptor) -> String {
        var parts: [String] = []
        if let duration = row.duration { parts.append(String(format: "%.1f s", duration)) }
        if let expiry = row.expiry { parts.append("Deletes " + expiry.formatted(date: .abbreviated, time: .omitted)) }
        if let reason = row.reason { parts.append(reason) }
        return parts.joined(separator: " · ")
    }
}
