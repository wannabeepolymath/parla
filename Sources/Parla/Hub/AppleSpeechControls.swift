import ParlaCore
import SwiftUI

/// Loaded once per view; empty means "unknown", which falls back to a code field.
@MainActor private enum SupportedLocalesKey { static var cache: [String]? }

/// Apple Speech language picker. Uses the system's supported list when it can
/// be read, otherwise a plain locale-code field. Unknown saved values stay visible.
struct AppleSpeechLocalePicker: View {
    let label: String
    @Binding var locale: String?
    var noneLabel = "Choose a language"
    @State private var supported: [String] = SupportedLocalesKey.cache ?? []

    var body: some View {
        Group {
            if supported.isEmpty {
                TextField(label, text: optBinding($locale), prompt: Text("en-US")).hubField().hubControl()
            } else {
                Picker(label, selection: $locale) {
                    Text(noneLabel).tag(Optional<String>.none)
                    Divider()
                    if let locale, !supported.contains(locale) { Text(localeDisplayName(locale)).tag(Optional(locale)) }
                    ForEach(supported, id: \.self) { Text(localeDisplayName($0)).tag(Optional($0)) }
                }
                .hubControl()
            }
        }
        .task {
            guard SupportedLocalesKey.cache == nil else { return }
            let list = await AppleSpeechNative.supportedLocaleIdentifiers()
                .sorted { localeDisplayName($0).localizedCaseInsensitiveCompare(localeDisplayName($1)) == .orderedAscending }
            if !list.isEmpty { SupportedLocalesKey.cache = list }
            supported = list
        }
    }
}

/// The Apple Speech language, as a row.
struct AppleSpeechLocaleRow: View {
    @Binding var locale: String?
    var noneLabel = "Choose a language"
    var body: some View {
        HubRow("Language", detail: "macOS may download it the first time") {
            AppleSpeechLocalePicker(label: "Apple Speech language", locale: $locale, noneLabel: noneLabel)
        }
    }
}

/// Scalar cached projection only. All actions route to the app's one owner.
/// Rendered as card rows: setup status, then removing a language.
struct AppleSpeechControls: View {
    @ObservedObject var model: HubModel
    var locale: String? = nil
    @State private var releaseLocale = ""

    private var working: Bool {
        [.checking, .waiting, .reserving, .downloading, .verifying, .stopping].contains(model.appleSpeechSnapshot.phase)
    }

    var body: some View {
        let chosen = locale ?? model.settings.appleSpeechLocale ?? ""
        let token = model.appleSpeechSnapshot.token
        HubRow("Language setup", detail: model.appleSpeechSnapshot.message) {
            HStack(spacing: 8) {
                if let fraction = model.appleSpeechSnapshot.progress?.fraction {
                    ProgressView(value: fraction).frame(width: 80)
                }
                if working {
                    Button("Cancel") { model.onAppleSpeechCancel(token) }.buttonStyle(HubButtonStyle())
                } else {
                    Button("Check Again") { model.onAppleSpeechAction(.recheck, chosen, token) }.buttonStyle(HubButtonStyle())
                    Button("Set Up") { model.onAppleSpeechAction(.prepare, chosen, token) }.buttonStyle(HubButtonStyle())
                }
            }
        }
        HubDivider()
        HubRow("Remove a downloaded language", detail: "Frees space for a language you no longer use") {
            HStack(spacing: 8) {
                AppleSpeechLocalePicker(label: "Language to remove", locale: Binding(
                    get: { releaseLocale.isEmpty ? nil : releaseLocale }, set: { releaseLocale = $0 ?? "" }), noneLabel: "Choose…")
                Button("Remove") { model.onAppleSpeechAction(.release, releaseLocale, token) }
                    .buttonStyle(HubButtonStyle())
                    .disabled(releaseLocale.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
