import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @State private var menu = false
    @State private var setup = false
    let destinations = [("Home", "house"), ("Scratchpad", "note.text"), ("Dictionary", "character.book.closed"), ("Snippets", "text.quote"), ("Models", "cpu"), ("Settings", "gearshape"), ("Local account", "person.crop.circle")]
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if ["Dictionary", "Snippets", "Models"].contains(coordinator.route) {
                    HStack {
                        Button { coordinator.route = "Home" } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel("Back to Home")
                        Spacer(); Text(coordinator.route).fontWeight(.semibold); Spacer(); Color.clear.frame(width: 44, height: 44)
                    }.padding(.horizontal, 16).padding(.bottom, 8)
                } else {
                HStack {
                    Button { menu = true } label: { Image(systemName: "line.3.horizontal").font(.title3).frame(width: 44, height: 44) }.accessibilityLabel("Open menu")
                    Spacer(); ParlaMark(size: 25); Spacer()
                    Button {
                        if coordinator.recording { coordinator.stop() }
                        else if coordinator.busy { coordinator.cancel() }
                        else { coordinator.start(pending: coordinator.session?.phase == .requested ? coordinator.session : nil) }
                    } label: {
                        Image(systemName: coordinator.recording ? "stop.fill" : "mic.fill").frame(width: 44, height: 44)
                            .background(coordinator.recording ? Color.lavender : Color("neutral100")).clipShape(Circle())
                    }.accessibilityLabel(coordinator.recording ? "Stop recording" : coordinator.busy ? "Cancel dictation" : "Start dictation")
                }.padding(.horizontal, 16).padding(.bottom, 8)
                }
                if coordinator.busy || coordinator.session?.phase == .requested { SessionBanner() }
                Group {
                    switch coordinator.route {
                    case "Scratchpad": NotesView()
                    case "Dictionary": DictionaryView()
                    case "Snippets": PairsView(kind: .snippets)
                    case "Models": ModelsView()
                    case "Settings": SettingsView()
                    case "Local account": LocalAccountView()
                    default: HistoryView()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.background(Color.paper).foregroundStyle(Color.ink)
                .font(.custom("Figtree-Light", size: 17))
                .toolbar(.hidden, for: .navigationBar)
                .sheet(isPresented: $menu) {
                    NavigationStack {
                        List {
                            Section { ParlaMark(size: 35).padding(.vertical, 20).listRowBackground(Color.clear) }
                            Section {
                                ForEach(destinations, id: \.0) { name, symbol in
                                    Button { coordinator.route = name; menu = false } label: { Label(name, systemImage: symbol).foregroundStyle(Color.ink).padding(.vertical, 6) }
                                }
                            }
                            Section { Button("Keyboard setup & practice") { menu = false; setup = true } }
                            Section { Text("On-device speech · Local data").font(.footnote).foregroundStyle(.secondary) }
                        }.scrollContentBackground(.hidden).background(Color.paper)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { menu = false } } }
                    }.presentationDetents([.large])
                }
                .fullScreenCover(isPresented: Binding(get: { !store.library.preferences.onboarded || setup }, set: { setup = $0 })) { OnboardingView() }
                .alert("Parla", isPresented: Binding(get: { coordinator.message != nil || store.error != nil || settings.error != nil }, set: { if !$0 { dismissAlert() } })) {
                    Button("OK") { dismissAlert() }
                } message: { Text(coordinator.message ?? store.error ?? settings.error ?? "") }
        }
    }
    func dismissAlert() { coordinator.message = nil; store.error = nil; settings.error = nil }
}
struct SessionBanner: View {
    @EnvironmentObject private var coordinator: DictationCoordinator
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: coordinator.recording ? "mic.fill" : "waveform")
                Text(title).fontWeight(.semibold)
                Spacer()
                Button("Cancel", role: .cancel) { coordinator.cancel() }
            }
            if coordinator.session?.phase == .requested && !coordinator.isStarting {
                Text("Start the microphone here, then return to your previous app manually. Parla can record for up to 5 minutes; iOS may interrupt it.").font(.footnote)
                Button("Start microphone") { coordinator.start(pending: coordinator.session) }.buttonStyle(ParlaButtonStyle())
            } else if coordinator.recording {
                HStack { Waveform(active: true); Spacer(); Button("Stop & transcribe") { coordinator.stop() }.fontWeight(.semibold) }
                Text("\(coordinator.inputName) · Return to your keyboard to stop and review.").font(.caption).foregroundStyle(.secondary)
            } else { ProgressView().frame(maxWidth: .infinity) }
        }.padding(18).background(Color.lavender).clipShape(RoundedRectangle(cornerRadius: 20)).padding(.horizontal, 20).padding(.bottom, 12)
    }
    var title: String {
        if coordinator.isStarting { return "Starting microphone…" }
        switch coordinator.session?.phase {
        case .recording: return "Listening"
        case .processing: return "Transcribing…"
        default: return "Keyboard dictation requested"
        }
    }
}
