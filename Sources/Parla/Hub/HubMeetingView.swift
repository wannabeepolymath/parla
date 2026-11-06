import Foundation
import ParlaCore
import SwiftUI

struct HubMeetingView: View {
    @ObservedObject var controller: MeetingHubController
    let openSettings: () -> Void
    @State private var consentAcknowledged = false
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
        return "Unless you choose Keep: raw audio is deleted \(success) after successful transcription, or after \(failed) if transcription does not finish. Transcripts are kept for \(transcript) from the start. Parla removes expired files when it next runs. Storage is private and excluded from backup."
    }
    var body: some View {
        let value = controller.model
        VStack(alignment:.leading,spacing:18) {
            VStack(alignment:.leading,spacing:4) {
                Text("Meetings").font(.system(size:26,weight:.semibold)).foregroundStyle(Theme.text)
                Text("Record your microphone and one selected app. Transcribe on this Mac.").font(.system(size:13)).foregroundStyle(Theme.muted)
            }
            // The action rail has no scrolling ancestor and no parent disabled state.
            VStack(alignment:.leading,spacing:8) {
                if value.stoppingAvailable {
                    Label("Meeting recording · " + (value.state == .stopping ? "Finishing" : "Active"),systemImage:"record.circle.fill")
                        .foregroundStyle(.red).font(.system(size:13,weight:.semibold))
                        .accessibilityLabel("Meeting recording indicator. " + value.status)
                }
                Text(value.status).font(.system(size:13,weight:.medium)).fixedSize(horizontal:false,vertical:true)
                    .accessibilityLabel("Meeting status: " + value.status)
                HStack {
                    if value.stoppingAvailable {
                        Button("Stop and save",action:controller.stopAndSave).accessibilityHint("Stops both sources and keeps saved meeting audio.")
                    } else if value.captureAvailable {
                        Button("Start and save recording",action:controller.startAndSave).disabled(!value.canStart)
                    } else {
                        Label("Recording unavailable",systemImage:"mic.slash").foregroundStyle(Theme.muted)
                    }
                    if value.state == .transcribing {
                        Button("Cancel transcription",action:controller.cancelTranscription)
                    } else {
                        Button("Transcribe saved audio",action:controller.transcribeRemaining).disabled(!value.canTranscribe)
                    }
                }
            }
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    HubSection("Audio sources",footer:"Application audio requires macOS 14.2 or later and System Audio Recording permission. Only the selected app is recorded; no screen video is captured. Apps using helper processes or multiple output devices may be unavailable.") {
                        HubRow("Microphone",detail:"Your microphone choice is frozen when recording starts.") {
                            Button("Choose microphone…",action:openSettings).disabled(value.stoppingAvailable)
                        }
                        Picker("Application audio",selection:Binding<UUID?>(get:{
                            if case .selectedApplication(let selected) = controller.sourceChoice { return selected.selectionID }
                            return UUID?.none
                        },set:{ id in
                            if let id,let app = controller.applications.first(where: { $0.selectionID == id }) {
                                _ = controller.acceptSourceChoice(.selectedApplication(app))
                            } else { _ = controller.acceptSourceChoice(.microphone) }
                        })) {
                            Text("Microphone only").tag(UUID?.none)
                            ForEach(controller.applications,id:\.selectionID) { app in
                                Text(app.label).tag(Optional(app.selectionID))
                            }
                        }.disabled(value.busy || value.stoppingAvailable || value.metadata != nil)
                        Button("Refresh running applications",action:controller.refreshApplications)
                            .disabled(value.busy || value.stoppingAvailable || value.metadata != nil)
                    }
                    Text("Audio and transcripts stay on this Mac and are never added to dictation History. Nothing is uploaded. Transcription is local; automatic AI cleanup and summaries are off.")
                        .font(.system(size:12)).foregroundStyle(Theme.muted).fixedSize(horizontal:false,vertical:true)
                    Text(retentionNotice)
                        .font(.system(size:12)).foregroundStyle(Theme.muted).fixedSize(horizontal:false,vertical:true)
                    Text("Closing Meetings or its window stops recording and saves the audio. Every new session requires Start and consent.")
                        .font(.system(size:12)).foregroundStyle(Theme.muted).fixedSize(horizontal:false,vertical:true)
                    Text("Up to one hour. Recording may stop sooner if storage or the microphone becomes unavailable.")
                        .font(.system(size:12)).foregroundStyle(Theme.muted).fixedSize(horizontal:false,vertical:true)
                    if let metadata = value.metadata {
                        VStack(alignment:.leading,spacing:5) {
                            Text("Started \(Date(timeIntervalSince1970:Double(metadata.created)/1_000_000_000).formatted(date:.abbreviated,time:.shortened))")
                            if metadata.kept { Text("Kept until you delete it") }
                            else {
                                Text("Transcript expires \(Date(timeIntervalSince1970:Double(metadata.expires)/1_000_000_000).formatted(date:.abbreviated,time:.shortened))")
                                if let raw = metadata.rawExpires {
                                    Text("Audio expires \(Date(timeIntervalSince1970:Double(raw)/1_000_000_000).formatted(date:.abbreviated,time:.shortened))")
                                } else if metadata.chunks.contains(where: { $0.audioRemoved }) { Text("Raw audio deleted") }
                            }
                        }.font(.system(size:12)).foregroundStyle(Theme.muted)
                        Toggle("Keep this meeting until I delete it",isOn:Binding(get:{ metadata.kept },set:controller.keepMeeting))
                            .disabled(value.busy || value.state != .stopped)
                        HStack {
                            Button("Open saved text",action:controller.openSavedText).disabled(!value.canRead)
                            Button("Copy text",action:controller.copyText).disabled(!value.canRead)
                        }
                        if let text = value.text {
                            Text("Saved raw text").font(.system(size:14,weight:.semibold))
                            Text(verbatim:text).font(.system(size:13)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                        }
                        Button("Delete saved audio and text…",role:.destructive) {
                            if let confirmation = controller.deleteConfirmation { deletion = .init(session:confirmation.session,intent:confirmation.intent) }
                        }.disabled(value.busy || value.stoppingAvailable)
                    }
                    if value.recoveryDeleteAvailable {
                        Button("Delete all meeting data…",role:.destructive) {
                            if let intent = controller.recoveryDeleteConfirmation { deletion = .init(session:nil,intent:intent) }
                        }.disabled(value.busy || value.stoppingAvailable)
                    }
                    VStack(alignment:.leading,spacing:8) {
                        Button("Retry opening saved meeting",action:controller.retryOpen).disabled(value.busy)
                        Button("Local recognition settings",action:openSettings)
                        Button("Microphone privacy settings",action:controller.openMicrophoneSettings)
                        Button("System audio privacy settings",action:controller.openApplicationPrivacy)
                    }
                }
                .padding(.trailing,8)
            }
        }
        .padding(28).padding(.top,20).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
        .background(Theme.bg).tint(Theme.accent)
        .sheet(item:Binding(get:{ controller.recordingChallenge },set:{ pending in
            if pending == nil,let current = controller.recordingChallenge { controller.confirmRecordingStart(id:current.id,affirmed:false) }
        })) { challenge in
            VStack(alignment:.leading,spacing:18) {
                Text("Record this meeting?").font(.headline)
                Text("Parla will save your microphone and the selected app’s audio on this Mac. macOS may ask for microphone or System Audio Recording access. After granting microphone access, press Start again.")
                    .fixedSize(horizontal:false,vertical:true)
                Toggle("Everyone in this meeting knows it's being recorded",isOn:$consentAcknowledged)
                HStack {
                    Button("Cancel") { controller.confirmRecordingStart(id:challenge.id,affirmed:false) }.keyboardShortcut(.cancelAction)
                    Button("Start recording") { controller.confirmRecordingStart(id:challenge.id,affirmed:consentAcknowledged) }
                        .disabled(!consentAcknowledged).keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width:430).onAppear { consentAcknowledged = false }
        }
        .sheet(item:$deletion) { confirmation in
            VStack(alignment:.leading,spacing:18) {
                Text(confirmation.session == nil ? "Delete all meeting data?" : "Delete this meeting’s saved audio and text?").font(.headline)
                Text("Copies you exported remain.").font(.body)
                HStack {
                    Button("Cancel") { deletion = nil }.keyboardShortcut(.cancelAction)
                    Button("Delete saved audio and text",role:.destructive) {
                        deletion = nil
                        if let session = confirmation.session { controller.deleteConfirmed(session:session,intent:confirmation.intent) }
                        else { controller.deleteAllMeetingDataConfirmed(intent:confirmation.intent) }
                    }
                }
            }.padding(24).frame(width:390)
        }
    }
}
