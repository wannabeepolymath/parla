import SwiftUI
import AVFoundation
import UIKit

struct HistoryView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator
    @EnvironmentObject private var store: LibraryStore
    @State private var search = ""
    @State private var detail: Transcript?
    @State private var delete: Transcript?
    var filtered: [Transcript] { store.library.transcripts.filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) || $0.raw.localizedCaseInsensitiveContains(search) } }
    var groups: [(Date, [Transcript])] {
        Dictionary(grouping: filtered, by: { Calendar.current.startOfDay(for: $0.date) }).sorted { $0.key > $1.key }.map { ($0.key, $0.value) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Your voice,\nready to send.").font(.custom("EBGaramond-Regular", size: 42)).lineSpacing(-2)
                HStack(spacing: 0) {
                    metric("\(store.library.transcripts.reduce(0) { $0 + $1.words })", "words saved")
                    Divider().frame(height: 36)
                    metric("\(store.library.transcripts.count)", "dictations")
                    Divider().frame(height: 36)
                    metric("\(Int(store.library.transcripts.reduce(0) { $0 + $1.duration } / 60))", "minutes recorded")
                }.padding(.vertical, 18).background(Color("hexF8F6FF")).clipShape(RoundedRectangle(cornerRadius: 20))
                HStack { Image(systemName: "magnifyingglass"); TextField("Search history", text: $search) }.padding(14).background(.white).clipShape(RoundedRectangle(cornerRadius: 14))
                if !coordinator.lastResult.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Latest result · temporary").font(.caption).foregroundStyle(.secondary)
                        Text(coordinator.lastResult).textSelection(.enabled)
                        HStack {
                            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = coordinator.lastResult }
                            Spacer(); ShareLink(item: coordinator.lastResult) { Image(systemName: "square.and.arrow.up") }
                        }
                    }.padding(18).background(Color.lavender.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 18))
                }
                HStack { Text("History").font(.custom("EBGaramond-Regular", size: 28)); Spacer(); Text("Only on this iPhone").font(.caption).foregroundStyle(.secondary) }
                if filtered.isEmpty {
                    EmptyCard(icon: "waveform", title: search.isEmpty ? "Think it. Speak it." : "No matches", detail: search.isEmpty ? "Tap the microphone to capture your first dictation. Your history starts with what you say." : "Try another word or phrase.")
                }
                ForEach(groups, id: \.0) { day, items in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(day, style: .date).font(.caption).foregroundStyle(.secondary)
                        ForEach(items) { item in
                            Button { detail = item } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(item.text.isEmpty ? "Dictation could not complete" : item.text).lineLimit(4).multilineTextAlignment(.leading)
                                    HStack {
                                        Text(item.date, style: .time); Spacer()
                                        if item.error != nil { Label("Needs attention", systemImage: "exclamationmark.circle") }
                                        else { Text("\(item.words) words") }
                                    }.font(.caption).foregroundStyle(.secondary)
                                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.white).clipShape(RoundedRectangle(cornerRadius: 18))
                            }.buttonStyle(.plain).contextMenu {
                                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.text }
                                Button("Retry", systemImage: "arrow.clockwise") { coordinator.retry(item) }
                                Button("Delete", systemImage: "trash", role: .destructive) { delete = item }
                            }
                        }
                    }
                }
                Text("Retention: \(store.library.preferences.retention.title). Usage totals describe retained history only.").font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }.sheet(item: $detail) { TranscriptDetail(transcript: $0) }
            .confirmationDialog("Delete this dictation and its audio?", isPresented: Binding(get: { delete != nil }, set: { if !$0 { delete = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) { if let delete { do { try store.deleteTranscript(delete.id) } catch { store.error = error.localizedDescription } }; delete = nil }
            }
    }
    func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) { Text(value).font(.custom("Manrope-ExtraLight", size: 25).weight(.semibold)); Text(label).font(.system(size: 11)).foregroundStyle(.secondary) }.frame(maxWidth: .infinity)
    }
}
struct TranscriptDetail: View {
    let transcript: Transcript
    @EnvironmentObject private var coordinator: DictationCoordinator
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var raw = false
    @State private var player: AVAudioPlayer?
    @State private var playbackError: String?
    @State private var confirmDelete = false
    var current: Transcript? { store.library.transcripts.first { $0.id == transcript.id } }
    var text: String { raw ? (current?.raw ?? "") : (current?.text ?? "") }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let item = current {
                        Text(item.date.formatted(date: .long, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        Picker("Transcript version", selection: $raw) { Text("Final").tag(false); Text("Raw").tag(true) }.pickerStyle(.segmented)
                        Text(text.isEmpty ? "No text available." : text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        if let error = item.error { Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.secondary) }
                        HStack {
                            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
                            Spacer(); ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
                        }
                        if let name = item.audioName, let url = store.audioURL(name) {
                            Button(player?.isPlaying == true ? "Stop playback" : "Play recording", systemImage: "play.circle") {
                                do {
                                    if player?.isPlaying == true { player?.stop(); player = nil }
                                    else {
                                        guard !coordinator.busy else { throw ParlaError.message("Finish dictation before playing audio.") }
                                        try AVAudioSession.sharedInstance().setCategory(.playback)
                                        try AVAudioSession.sharedInstance().setActive(true)
                                        player = try AVAudioPlayer(contentsOf: url); player?.play()
                                    }
                                } catch { playbackError = error.localizedDescription }
                            }
                        }
                        Button("Retry transcription / cleanup", systemImage: "arrow.clockwise") { stopPlayback(); coordinator.retry(item); dismiss() }.disabled(coordinator.busy)
                        Text("Retry creates a separate attempt with your current settings. Retained audio is transcribed again on this iPhone; text-only attempts retry cleanup.").font(.caption).foregroundStyle(.secondary)
                        Button("Delete dictation", role: .destructive) { confirmDelete = true }
                    } else { Text("This dictation is no longer retained.") }
                }.padding(24)
            }.navigationTitle("Dictation").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .onDisappear { stopPlayback() }
                .onChange(of: current?.id) { _, _ in if current == nil { stopPlayback() } }
                .alert("Playback", isPresented: Binding(get: { playbackError != nil }, set: { if !$0 { playbackError = nil } })) { Button("OK") { playbackError = nil } } message: { Text(playbackError ?? "") }
                .confirmationDialog("Delete dictation and recording?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { stopPlayback(); do { try store.deleteTranscript(transcript.id); dismiss() } catch { playbackError = error.localizedDescription } }
                }
        }
    }
    func stopPlayback() { player?.stop(); player = nil; if !coordinator.busy { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) } }
}
