import SwiftUI

struct HubMeetingView: View {
    @ObservedObject var controller: MeetingHubController
    let openSettings: () -> Void
    @State private var deletion: DeleteConfirmation?
    private struct DeleteConfirmation: Identifiable { let id = UUID(),session: UUID,intent: UUID }
    var body: some View {
        let value = controller.model
        VStack(alignment:.leading,spacing:18) {
            VStack(alignment:.leading,spacing:4) {
                Text("Meetings").font(.system(size:26,weight:.semibold)).foregroundStyle(Theme.text)
                Text("Record your microphone, then transcribe saved audio.").font(.system(size:13)).foregroundStyle(Theme.muted)
            }
            // The action rail has no scrolling ancestor and no parent disabled state.
            VStack(alignment:.leading,spacing:8) {
                Text(value.status).font(.system(size:13,weight:.medium)).fixedSize(horizontal:false,vertical:true)
                    .accessibilityLabel("Meeting status: " + value.status)
                HStack {
                    if value.stoppingAvailable {
                        Button("Stop and save",action:controller.stopAndSave).accessibilityHint("Stops recording and keeps saved microphone audio.")
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
                    HubSection("Microphone only",footer:"System and app audio are unavailable.") {
                        HubRow(value.source,detail:"Your microphone choice is frozen when recording starts. A later Settings change applies to the next recording.") {
                            Button("Choose microphone…",action:openSettings).disabled(value.stoppingAvailable)
                        }
                    }
                    Text("Start saves microphone audio on this Mac. Saved audio and text expire seven days after recording starts and are removed when Parla can safely finish deletion. Closing this page or window stops recording and keeps the saved audio.")
                        .font(.system(size:12)).foregroundStyle(Theme.muted).fixedSize(horizontal:false,vertical:true)
                    Text("Up to one hour. Recording may stop sooner if storage or the microphone becomes unavailable.")
                        .font(.system(size:12)).foregroundStyle(Theme.muted).fixedSize(horizontal:false,vertical:true)
                    if let metadata = value.metadata {
                        VStack(alignment:.leading,spacing:5) {
                            Text("Started \(Date(timeIntervalSince1970:Double(metadata.created)/1_000_000_000).formatted(date:.abbreviated,time:.shortened))")
                            Text("Expires \(Date(timeIntervalSince1970:Double(metadata.expires)/1_000_000_000).formatted(date:.abbreviated,time:.shortened))")
                        }.font(.system(size:12)).foregroundStyle(Theme.muted)
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
                    VStack(alignment:.leading,spacing:8) {
                        Button("Retry opening saved meeting",action:controller.retryOpen).disabled(value.busy)
                        Button("Local recognition settings",action:openSettings)
                        Button("Microphone privacy settings",action:controller.openMicrophoneSettings)
                    }
                }
                .padding(.trailing,8)
            }
        }
        .padding(28).padding(.top,20).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
        .background(Theme.bg).tint(Theme.accent)
        .sheet(item:$deletion) { confirmation in
            VStack(alignment:.leading,spacing:18) {
                Text("Delete this meeting’s saved audio and text?").font(.headline)
                Text("Copies you exported and independent History entries remain.").font(.body)
                HStack {
                    Button("Cancel") { deletion = nil }.keyboardShortcut(.cancelAction)
                    Button("Delete saved audio and text",role:.destructive) {
                        deletion = nil; controller.deleteConfirmed(session:confirmation.session,intent:confirmation.intent)
                    }
                }
            }.padding(24).frame(width:390)
        }
    }
}
