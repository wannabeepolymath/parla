import ParlaCore
import SwiftUI

/// Scalar cached projection only. All actions route to the app's one owner.
struct AppleSpeechControls: View {
    @ObservedObject var model: HubModel
    var locale: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Apple Speech · optional post-stop batch").font(.headline)
            Text("Words apply to cleanup only; Apple Speech does not use ASR dictionary hints or initial prompts. No automatic language detection, shadow preview, or Undo Canceled Capture.")
                .font(.caption).foregroundStyle(Theme.muted)
            Text("Prepare language permits Apple-managed language downloads and updates and reserves the language for Parla. Cancel requests cancellation; macOS may retry downloads later.")
                .font(.caption)
            Text(model.appleSpeechSnapshot.message).font(.callout)
            if let fraction = model.appleSpeechSnapshot.progress?.fraction { ProgressView(value: fraction) }
            let chosen = locale ?? model.settings.appleSpeechLocale ?? ""
            let token = model.appleSpeechSnapshot.token
            HStack {
                Button("Prepare language") { model.onAppleSpeechAction(.prepare, chosen, token) }
                Button("Recheck") { model.onAppleSpeechAction(.recheck, chosen, token) }
                Button("Cancel") { model.onAppleSpeechCancel(token) }
            }
            HStack {
                TextField("Unused reservation locale", text: $releaseLocale).hubField()
                Button("Release Parla reservation") { model.onAppleSpeechAction(.release, releaseLocale, token) }
            }
            Text("Release applies only to a known Parla-owned reservation with no selected, profile or live references. It does not delete shared disk assets. Safe Start tracks catalog Whisper preparation only.")
                .font(.caption).foregroundStyle(Theme.muted)
        }
    }
    @State private var releaseLocale = ""
}
