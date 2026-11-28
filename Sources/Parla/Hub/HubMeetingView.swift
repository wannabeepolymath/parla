import Foundation
import ParlaCore
import SwiftUI

struct HubMeetingView: View {
    @ObservedObject var controller: MeetingHubController
    let openSettings: () -> Void
    @Binding var microphone: String?
    var settingsLocked = false
    @State private var consentAcknowledged = false
    @State private var showRetention = false
    private var retentionSummary: String {
        let hours = MeetingSession.RecordingPolicy.successfulAudioRetention / 3_600_000_000_000
        let days = MeetingSession.RecordingPolicy.transcriptRetention / 86_400_000_000_000
        return "Audio \(hours) h · Transcript \(days) days"
    }
    @State private var deletion: DeleteConfirmation?
    private struct DeleteConfirmation: Identifiable { let id = UUID(),session: UUID?,intent: UUID }
    private static func policyDuration(_ nanoseconds: Int64, units: NSCalendar.Unit = [.day,.hour,.minute,.second]) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier:.gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT:0) ?? calendar.timeZone
        formatter.calendar = calendar; formatter.allowedUnits = units; formatter.unitsStyle = .full
        let seconds = Double(nanoseconds)/1_000_000_000
        return formatter.string(from:seconds) ?? "\(seconds) seconds"
    }
    private var retentionNotice: String {
        let success = Self.policyDuration(MeetingSession.RecordingPolicy.successfulAudioRetention,units:[.hour,.minute,.second])
        let failed = Self.policyDuration(MeetingSession.RecordingPolicy.failedAudioRetention)
        let transcript = Self.policyDuration(MeetingSession.RecordingPolicy.transcriptRetention)
        return "Unless you keep a meeting, its audio is deleted \(success) after transcription (or after \(failed) if it isn’t transcribed), and its transcript \(transcript) after the meeting starts. Expired files are removed the next time Parla runs."
    }
    private func date(_ nanoseconds: Int64) -> String {
        Date(timeIntervalSince1970: Double(nanoseconds) / 1_000_000_000).formatted(date: .abbreviated, time: .shortened)
    }
    private var sourcesLocked: Bool { controller.model.busy || controller.model.stoppingAvailable || controller.model.metadata != nil }

    var body: some View {
        let value = controller.model
        VStack(alignment: .leading, spacing: 0) {
            // The action rail has no scrolling ancestor and no parent disabled state.
            VStack(alignment: .leading, spacing: HubLayout.sectionSpacing) {
                HubPageHeader(title: "Meetings", subtitle: HubPage.meetings.subtitle)
                HubSection(nil, footer: value.stoppingAvailable
                           ? "Recording until you click Stop and Save. Leaving this page stops it, so Parla asks first." : nil) {
                    HStack(spacing: 12) {
                        if value.stoppingAvailable, value.state != .stopping, let started = value.metadata?.created {
                            RecordingClock(startedNanoseconds: started)
                        }
                    HubRow(value.stoppingAvailable ? (value.state == .stopping ? "Finishing recording" : "Recording") : "Meeting recorder",
                           detail: value.stoppingAvailable ? (value.message ?? "From " + value.source) : value.status + (value.captureAvailable && value.state == .idle ? " Up to an hour." : "")) {
                        HStack(spacing: 8) {
                            if value.stoppingAvailable {
                                Image(systemName: "record.circle.fill").foregroundStyle(Theme.danger)
                                    .accessibilityLabel("Meeting recording indicator. " + value.status)
                            }
                            if value.state == .transcribing {
                                Button("Cancel Transcription", action: controller.cancelTranscription).buttonStyle(HubButtonStyle())
                            } else if value.canTranscribe {
                                Button("Transcribe", action: controller.transcribeRemaining).buttonStyle(HubButtonStyle(kind: value.stoppingAvailable ? .normal : .primary))
                            }
                            if value.stoppingAvailable {
                                Button("Stop and Save", action: controller.stopAndSave)
                                    .buttonStyle(HubButtonStyle(kind: .primary))
                                    .accessibilityHint("Stops both sources and keeps saved meeting audio.")
                            } else if value.captureAvailable {
                                if !value.canTranscribe {
                                    Button("Start Recording", action: controller.startAndSave)
                                        .buttonStyle(HubButtonStyle(kind: .primary)).disabled(!value.canStart)
                                }
                            } else {
                                Label("Recording unavailable", systemImage: "mic.slash")
                                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            }
                            HubMoreMenu(label: "More meeting actions") {
                                Button("Reopen Saved Meeting", action: controller.retryOpen).disabled(value.busy)
                                Divider()
                                Button("Speech Settings…", action: openSettings)
                                Button("Microphone Access…", action: controller.openMicrophoneSettings)
                                Button("App Audio Access…", action: controller.openApplicationPrivacy)
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Meeting status: " + value.status)
                    .padding(.leading, value.stoppingAvailable && value.metadata != nil && value.state != .stopping ? -HubLayout.rowInset : 0)
                    }
                    .padding(.leading, value.stoppingAvailable && value.metadata != nil && value.state != .stopping ? HubLayout.rowInset : 0)
                }
            }
            .hubColumn(bottom: HubLayout.sectionSpacing)

            ScrollView {
                VStack(alignment: .leading, spacing: HubLayout.sectionSpacing) {
                    HubSection("Audio sources", footer: "Recording an app needs macOS 14.2 or later. Only its audio is recorded, not your screen. Some apps can’t be recorded.") {
                        HubRow("Microphone", detail: MicrophonePicker.detail(for: microphone) ?? "Changes apply to the next recording") {
                            MicrophonePicker(selection: $microphone).disabled(value.stoppingAvailable || settingsLocked)
                        }
                        HubDivider()
                        HubRow("Also record an app", detail: "Its sound only, like the other side of a call") {
                            HStack(spacing: 4) {
                                Picker("App audio", selection: Binding<UUID?>(get: {
                                    if case .selectedApplication(let selected) = controller.sourceChoice { return selected.selectionID }
                                    return UUID?.none
                                }, set: { id in
                                    if let id, let app = controller.applications.first(where: { $0.selectionID == id }) {
                                        _ = controller.acceptSourceChoice(.selectedApplication(app))
                                    } else { _ = controller.acceptSourceChoice(.microphone) }
                                })) {
                                    Text("None").tag(UUID?.none)
                                    ForEach(controller.applications, id: \.selectionID) { app in
                                        Text(app.label).tag(Optional(app.selectionID))
                                    }
                                }
                                .hubControl()
                                .disabled(sourcesLocked)
                                HubIconButton("arrow.clockwise", label: "Refresh apps", action: controller.refreshApplications)
                                    .disabled(sourcesLocked)
                            }
                        }
                    }
                    if let metadata = value.metadata {
                        HubSection("This meeting") {
                            HubRow("Started") { HubValue(date(metadata.created)) }
                            HubDivider()
                            if metadata.kept {
                                HubRow("Kept", detail: "Until you delete it")
                            } else {
                                HubRow("Transcript expires") { HubValue(date(metadata.expires)) }
                                if let raw = metadata.rawExpires {
                                    HubDivider()
                                    HubRow("Audio expires") { HubValue(date(raw)) }
                                } else if metadata.chunks.contains(where: { $0.audioRemoved }) {
                                    HubDivider()
                                    HubRow("Audio") { HubValue("Deleted") }
                                }
                            }
                            HubDivider()
                            HubToggleRow("Keep until I delete it", isOn: Binding(get: { metadata.kept }, set: controller.keepMeeting))
                                .disabled(value.busy || value.state != .stopped)
                            HubDivider()
                            HStack(spacing: 8) {
                                Button("Delete Meeting…") {
                                    if let confirmation = controller.deleteConfirmation { deletion = .init(session: confirmation.session, intent: confirmation.intent) }
                                }
                                .buttonStyle(HubButtonStyle(kind: .danger))
                                .disabled(value.busy || value.stoppingAvailable)
                                Spacer()
                                Button("Open Saved Text", action: controller.openSavedText).buttonStyle(HubButtonStyle()).disabled(!value.canRead)
                                Button("Copy Text", action: controller.copyText).buttonStyle(HubButtonStyle()).disabled(!value.canRead)
                            }
                            .hubInset()
                        }
                        if let text = value.text {
                            HubSection("Transcript") {
                                Text(verbatim: text).font(.system(size: 13)).foregroundStyle(Theme.text).textSelection(.enabled)
                                    .hubInset()
                            }
                        }
                    }
                    if value.recoveryDeleteAvailable {
                        HubSection(nil) {
                            HubRow("Leftover meeting data", detail: "Files from a meeting Parla couldn’t open") {
                                Button("Delete All…") {
                                    if let intent = controller.recoveryDeleteConfirmation { deletion = .init(session: nil, intent: intent) }
                                }
                                .buttonStyle(HubButtonStyle(kind: .danger))
                                .disabled(value.busy || value.stoppingAvailable)
                            }
                        }
                    }
                    HubSection("Storage") {
                        HubRow("Kept on this Mac", detail: "Audio and transcripts aren’t added to History")
                        HubDivider()
                        HubDisclosureRow(title: "How long meetings are kept", summary: retentionSummary, isExpanded: $showRetention)
                        if showRetention {
                            HubDivider()
                            Text(retentionNotice).font(.system(size: 12)).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true).hubInset()
                        }
                    }
                }
                .hubColumn(top: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg).tint(Theme.accent)
        .sheet(item: Binding(get: { controller.recordingChallenge }, set: { pending in
            if pending == nil, let current = controller.recordingChallenge { controller.confirmRecordingStart(id: current.id, affirmed: false) }
        })) { challenge in
            HubSheet(title: "Record this meeting?", width: 440) {
                Text("Parla will save your microphone and the selected app’s audio on this Mac. If macOS asks for access, allow it, then press Start again.")
                    .font(.system(size: 13)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Everyone in this meeting knows it’s being recorded", isOn: $consentAcknowledged)
                    .font(.system(size: 13))
            } actions: {
                Button("Cancel") { controller.confirmRecordingStart(id: challenge.id, affirmed: false) }
                    .buttonStyle(HubButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Start Recording") { controller.confirmRecordingStart(id: challenge.id, affirmed: consentAcknowledged) }
                    .buttonStyle(HubButtonStyle(kind: .primary))
                    .disabled(!consentAcknowledged).keyboardShortcut(.defaultAction)
            }
            .onAppear { consentAcknowledged = false }
        }
        .sheet(item: $deletion) { confirmation in
            HubSheet(title: confirmation.session == nil ? "Delete all meeting data?" : "Delete this meeting’s audio and transcript?", width: 400) {
                Text("Files you exported aren’t affected.").font(.system(size: 13)).foregroundStyle(Theme.text)
            } actions: {
                Button("Cancel") { deletion = nil }.buttonStyle(HubButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Delete") {
                    deletion = nil
                    if let session = confirmation.session { controller.deleteConfirmed(session: session, intent: confirmation.intent) }
                    else { controller.deleteAllMeetingDataConfirmed(intent: confirmation.intent) }
                }
                .buttonStyle(HubButtonStyle(kind: .danger))
            }
        }
    }
}

/// Elapsed recording time against the one-hour limit, ticking once a second.
private struct RecordingClock: View {
    let startedNanoseconds: Int64
    // ponytail: mirrors the "up to an hour" recording limit stated in the UI copy.
    private static let limit: TimeInterval = 3_600
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = max(0, context.date.timeIntervalSince1970 - Double(startedNanoseconds) / 1_000_000_000)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.format(elapsed))
                    .font(.system(size: 20, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.text)
                Text(elapsed < Self.limit ? "\(Int((Self.limit - elapsed) / 60)) min left" : "At the limit")
                    .font(.system(size: 11)).foregroundStyle(elapsed > Self.limit - 300 ? Theme.warning : Theme.muted)
            }
            .frame(minWidth: 64, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Recording time \(Self.format(elapsed))")
        }
    }
    private static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
