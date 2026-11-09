import ParlaCore
import SwiftUI

/// Scalar cached projection only. All actions route to the app's one owner.
struct AppleSpeechControls: View {
    @ObservedObject var model: HubModel
    var locale: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Apple Speech").font(.headline)
            Text("Set up the language before you dictate. macOS may download it.")
                .font(.caption).foregroundStyle(Theme.muted)
            Text(model.appleSpeechSnapshot.message).font(.callout)
            if let fraction = model.appleSpeechSnapshot.progress?.fraction { ProgressView(value: fraction) }
            let chosen = locale ?? model.settings.appleSpeechLocale ?? ""
            let token = model.appleSpeechSnapshot.token
            HStack {
                Button("Set up language") { model.onAppleSpeechAction(.prepare, chosen, token) }
                Button("Check again") { model.onAppleSpeechAction(.recheck, chosen, token) }
                Button("Cancel") { model.onAppleSpeechCancel(token) }
            }
            HStack {
                TextField("Language you no longer use, e.g. fr-FR", text: $releaseLocale).hubField()
                Button("Release language") { model.onAppleSpeechAction(.release, releaseLocale, token) }
            }
        }
    }
    @State private var releaseLocale = ""
}
