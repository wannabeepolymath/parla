import SwiftUI
import AVFoundation
import UIKit

struct OnboardingView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var coordinator: DictationCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    @State private var permission = AVAudioApplication.shared.recordPermission
    @State private var practice = ""
    @State private var permissionMessage: String?
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                HStack { ParlaMark(size: 29); Spacer(); Button("Skip setup") { finish() } }
                ProgressView(value: Double(page + 1), total: 4).tint(Color("primary500"))
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        switch page {
                        case 0:
                            Text("Less typing.\nMore you.").font(.custom("EBGaramond-Regular", size: 55))
                            Waveform(active: true).frame(maxWidth: .infinity).padding(.vertical, 35).background(Color.lavender).clipShape(RoundedRectangle(cornerRadius: 32))
                            Text("Speak naturally. Parla turns your voice into text on this iPhone, then tidies it if you want.").font(.title3)
                            Text("Speech recognition runs on this iPhone with a model you download. Your notes and history live here too. No sign-in.").foregroundStyle(.secondary)
                        case 1:
                            Text("Your voice,\ninside your apps.").font(.custom("EBGaramond-Regular", size: 43))
                            setupRow("1", "Add Parla", "iPhone Settings → General → Keyboard → Keyboards → Add New Keyboard → Parla.")
                            setupRow("2", "Allow Full Access", "Tap Parla in Keyboards, enable Allow Full Access, and confirm. This lets the keyboard share dictation requests and results with Parla. It does not give the keyboard a microphone or send what you type.")
                            setupRow("3", "Dictate in another app", "Request dictation from the keyboard. Open Parla, tap Start microphone, then return to the app you were using. Stop from the keyboard, review, then tap Insert.")
                            Button("Open Parla’s Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }.buttonStyle(ParlaButtonStyle(dark: false))
                            Text("The Settings link opens Parla’s app settings; navigate manually if the keyboard controls are elsewhere. Password fields and apps that block other keyboards use Apple’s keyboard.").font(.footnote).foregroundStyle(.secondary)
                            Button(permission == .granted ? "Microphone allowed" : "Allow microphone") {
                                Task { let allowed = await AVAudioApplication.requestRecordPermission(); permission = AVAudioApplication.shared.recordPermission; if !allowed { permissionMessage = "Enable Microphone in iPhone Settings → Parla when you are ready. You can continue without it." } }
                            }.buttonStyle(ParlaButtonStyle()).disabled(permission == .granted)
                        case 2:
                            Text("A little more\nyou.").font(.custom("EBGaramond-Regular", size: 45))
                            NavigationLink { ModelsView() } label: { Label("Choose a speech model", systemImage: "cpu").frame(maxWidth: .infinity, alignment: .leading).padding(20).background(.white).clipShape(RoundedRectangle(cornerRadius: 18)) }
                            Text("On-device speech, local history").font(.headline)
                            Text("Audio never leaves this iPhone. Optional AI cleanup runs with Apple Intelligence on this iPhone, or sends your transcript, dictionary and snippets to your chosen provider. Online providers use your API key and may charge for use; their data policies apply. Parla does not read surrounding text or contacts, or collect analytics.")
                            Picker("Keep text & audio", selection: Binding(get: { store.library.preferences.retention }, set: { policy in var preferences = store.library.preferences; preferences.retention = policy; do { try store.savePreferences(preferences) } catch { permissionMessage = error.localizedDescription } })) {
                                ForEach(RetentionPolicy.allCases) { Text($0.title).tag($0) }
                            }.pickerStyle(.segmented)
                            Text("This controls saved dictations and recordings, not notes. Never still lets Parla process your speech and keep the latest result for two minutes. After that, the result cannot be used and is deleted when Parla or its keyboard next opens. With 24 hours, older dictations are deleted while Parla is open or when you next open it.").font(.footnote).foregroundStyle(.secondary)
                        default:
                            Text("Your turn.").font(.custom("EBGaramond-Regular", size: 50))
                            Text("Practice typing here, or switch to the Parla keyboard using the globe. Download a speech model in Models to try dictation.")
                            TextEditor(text: $practice).frame(minHeight: 160).padding(12).background(.white).clipShape(RoundedRectangle(cornerRadius: 18)).overlay(alignment: .topLeading) { if practice.isEmpty { Text("Try your keyboard here…").foregroundStyle(.secondary).padding(20).allowsHitTesting(false) } }
                            Text("To dictate, request from the keyboard, open Parla and start the microphone. Return to your app, stop, review and insert. Always review names and punctuation before sending.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                Button(page == 3 ? "Start using Parla" : "Continue") { if page < 3 { page += 1 } else { finish() } }.buttonStyle(ParlaButtonStyle())
                if page > 0 { Button("Back") { page -= 1 }.frame(maxWidth: .infinity) }
            }.padding(26).background(Color.paper).foregroundStyle(Color.ink)
                .font(.custom("Figtree-Light", size: 17))
                .alert("Setup", isPresented: Binding(get: { permissionMessage != nil }, set: { if !$0 { permissionMessage = nil } })) { Button("OK") { permissionMessage = nil } } message: { Text(permissionMessage ?? "") }
        }
    }
    func setupRow(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 15) {
            Text(number).font(.headline).frame(width: 30, height: 30).background(Color.lavender).clipShape(Circle())
            VStack(alignment: .leading, spacing: 6) { Text(title).fontWeight(.semibold); Text(detail).font(.subheadline).foregroundStyle(.secondary) }
        }
    }
    func finish() {
        var preferences = store.library.preferences; preferences.onboarded = true
        do { try store.savePreferences(preferences); dismiss() } catch { permissionMessage = error.localizedDescription }
    }
}
