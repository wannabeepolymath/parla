import SwiftUI
import UIKit
import ParlaCore

struct NotesView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var coordinator: DictationCoordinator
    @State private var search = ""
    @State private var editing: Note?
    @State private var deleting: Note?
    var notes: [Note] { store.library.notes.filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) }.sorted { $0.date > $1.date } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack { Text("Scratchpad").font(.custom("EBGaramond-Regular", size: 38)); Spacer() }
                Text("A place for the things on your mind. Saved only on this iPhone.").foregroundStyle(.secondary)
                TextField("Search notes", text: $search).padding(14).background(.white).clipShape(RoundedRectangle(cornerRadius: 14))
                if notes.isEmpty { EmptyCard(icon: "note.text", title: "Catch a thought", detail: "Create a note, or dictate directly into your scratchpad.") }
                ForEach(notes) { note in
                    Button { editing = note } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(note.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            Text(note.text.isEmpty ? "Empty note" : note.text).lineLimit(6).multilineTextAlignment(.leading)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(20).background(.white).clipShape(RoundedRectangle(cornerRadius: 18))
                    }.buttonStyle(.plain).contextMenu {
                        ShareLink(item: note.text)
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = note }
                    }
                }
                Button("Dictate a new note", systemImage: "mic") { coordinator.start(destination: .note) }.buttonStyle(ParlaButtonStyle(dark: false)).disabled(coordinator.busy)
            }.padding(24).padding(.bottom, 64)
        }.overlay(alignment: .bottomTrailing) {
            Button { editing = Note() } label: { Image(systemName: "plus").font(.title2).frame(width: 56, height: 56).background(Color.ink).foregroundStyle(.white).clipShape(Circle()).shadow(color: .black.opacity(0.12), radius: 8, y: 3) }.accessibilityLabel("New note").padding(24)
        }.sheet(item: $editing) { NoteEditor(note: $0) }
            .confirmationDialog("Delete this note?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) { if let deleting { do { try store.mutate { $0.notes.removeAll { $0.id == deleting.id } } } catch { store.error = error.localizedDescription } }; deleting = nil }
            }
    }
}
struct NoteEditor: View {
    let note: Note
    @EnvironmentObject private var coordinator: DictationCoordinator
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var dictationID: UUID?
    @State private var insertionDone = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Local note · Save to keep changes").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $coordinator.noteDraft).font(.custom("Figtree-Light", size: 20)).scrollContentBackground(.hidden)
                if coordinator.session?.id == dictationID, coordinator.busy {
                    HStack {
                        if coordinator.session?.phase == .processing { ProgressView(); Text("Transcribing…") }
                        else { Text(coordinator.recording ? "Listening" : "Starting microphone…") }
                        Spacer(); Button("Cancel dictation") { coordinator.cancel() }
                    }.font(.footnote)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                HStack {
                    ShareLink(item: coordinator.noteDraft) { Label("Share", systemImage: "square.and.arrow.up") }
                    Spacer()
                    Button(coordinator.recording && coordinator.session?.id == dictationID ? "Stop" : "Dictate", systemImage: "mic") {
                        if coordinator.recording && coordinator.session?.id == dictationID { coordinator.stop() }
                        else if !coordinator.busy {
                            coordinator.start(); dictationID = coordinator.session?.id; insertionDone = false
                        }
                    }.disabled(coordinator.busy && coordinator.session?.id != dictationID)
                }.padding(.vertical, 12)
            }.padding(24).background(Color.paper).navigationTitle("Scratchpad").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { cancelOwnedRecording(); coordinator.closeNoteEditor(); dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") {
                        do { try coordinator.saveDraft(); dismiss() } catch { self.error = error.localizedDescription }
                    }.disabled(coordinator.busy) }
                }.onAppear { coordinator.openNoteEditor(note) }
                .onChange(of: coordinator.session) { _, session in
                    guard !insertionDone, let session, session.id == dictationID, session.phase == .completed, let text = session.result else { return }
                    coordinator.noteDraft += (coordinator.noteDraft.isEmpty ? "" : "\n") + text
                    insertionDone = true
                }
                .onDisappear { cancelOwnedRecording(); coordinator.closeNoteEditor() }
                .interactiveDismissDisabled(coordinator.busy)
        }
    }
    func cancelOwnedRecording() { if coordinator.session?.id == dictationID && coordinator.busy { coordinator.cancel() } }
}
/// Saved order is priority for the recognition and cleanup hint budgets.
struct DictionaryView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var word = ""
    var words: [String] { settings.current.dictionary }
    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Add a word or name", text: $word).textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit(add)
                    Button("Add", action: add).disabled(VocabularyHints.normalized(word).isEmpty)
                }
            }
            Section {
                ForEach(Array(words.enumerated()), id: \.offset) { index, entry in
                    Text(entry)
                        .swipeActions(edge: .leading) { reorder(index) }
                        .swipeActions { Button("Delete", role: .destructive) { settings.update { $0.dictionary.remove(at: index) } } }
                }
                if words.isEmpty { Text("Names, product terms and spellings you use.").foregroundStyle(.secondary) }
            } header: { Text("Priority order") } footer: {
                Text("Words guide recognition and cleanup. Earlier words win when the \(VocabularyHints.asrBytes)-byte recognition hint or \(VocabularyHints.cleanupBytes)-byte cleanup budget is full; one word may use up to \(VocabularyHints.maxHintBytes) bytes. Swipe right to move a word, left to delete.")
            }
        }.scrollContentBackground(.hidden).background(Color.paper).navigationTitle("Dictionary")
    }
    func add() {
        let entry = VocabularyHints.normalized(word)
        guard !entry.isEmpty else { return }
        settings.update { state in if !state.dictionary.contains(where: { $0.caseInsensitiveCompare(entry) == .orderedSame }) { state.dictionary.append(entry) } }
        word = ""
    }
    @ViewBuilder func reorder(_ index: Int) -> some View {
        if index > 0 { Button("Up") { settings.update { $0.dictionary.swapAt(index, index - 1) } }.tint(.indigo) }
        if index < words.count - 1 { Button("Down") { settings.update { $0.dictionary.swapAt(index, index + 1) } } }
    }
}

/// Snippets (whole-dictation triggers) and literal replacements share one editor.
struct PairsView: View {
    enum Kind { case snippets, replacements }
    struct Pair: Identifiable { var id = UUID(); var index: Int?; var from = ""; var to = "" }
    let kind: Kind
    @EnvironmentObject private var settings: AppSettings
    @State private var editing: Pair?
    var pairs: [(String, String)] {
        kind == .snippets ? settings.current.snippets.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }.map { ($0.key, $0.value) }
            : settings.current.replacements.map { ($0.source, $0.replacement) }
    }
    var body: some View {
        List {
            Section {
                ForEach(Array(pairs.enumerated()), id: \.offset) { index, pair in
                    Button { editing = Pair(index: index, from: pair.0, to: pair.1) } label: {
                        VStack(alignment: .leading, spacing: 4) { Text(pair.0).foregroundStyle(Color.ink); Text(pair.1).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    .swipeActions(edge: .leading) { if kind == .replacements { reorder(index) } }
                    .swipeActions { Button("Delete", role: .destructive) { remove(index) } }
                }
                Button("Add", systemImage: "plus") { editing = Pair() }
            } footer: {
                Text(kind == .snippets
                     ? "When a whole dictation is just the trigger, its text is inserted exactly. A trigger inside a longer dictation goes to cleanup as a hint."
                     : "Exact, case-sensitive swaps after cleanup, matched at word edges. Longer text wins; earlier rows break ties. Swipe right to reorder.")
            }
        }.scrollContentBackground(.hidden).background(Color.paper).navigationTitle(kind == .snippets ? "Snippets" : "Replacements")
            .sheet(item: $editing) { PairEditor(pair: $0, kind: kind) { pair in save(pair) } }
    }
    func remove(_ index: Int) {
        let key = pairs[index].0
        settings.update { state in if kind == .snippets { state.snippets[key] = nil } else { state.replacements.remove(at: index) } }
    }
    @ViewBuilder func reorder(_ index: Int) -> some View {
        if index > 0 { Button("Up") { settings.update { $0.replacements.swapAt(index, index - 1) } }.tint(.indigo) }
        if index < pairs.count - 1 { Button("Down") { settings.update { $0.replacements.swapAt(index, index + 1) } } }
    }
    /// Returns a problem to show, or nil once saved.
    func save(_ pair: Pair) -> String? {
        let from = pair.from.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, !pair.to.isEmpty else { return "Fill in both fields." }
        let old = pair.index.map { pairs[$0].0 }
        if kind == .snippets {
            guard from == old || settings.current.snippets[from] == nil else { return "That trigger already exists." }
            settings.update { state in if let old { state.snippets[old] = nil }; state.snippets[from] = pair.to }
        } else {
            let rule = LiteralReplacement(source: from, replacement: pair.to)
            settings.update { state in if let index = pair.index { state.replacements[index] = rule } else { state.replacements.append(rule) } }
        }
        return nil
    }
}
struct PairEditor: View {
    @State var pair: PairsView.Pair
    let kind: PairsView.Kind
    let save: (PairsView.Pair) -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var problem: String?
    var body: some View {
        NavigationStack {
            Form {
                Section(kind == .snippets ? "When the whole dictation is" : "Replace exactly") { TextField("Text", text: $pair.from).textInputAutocapitalization(.never).autocorrectionDisabled() }
                Section(kind == .snippets ? "Insert" : "With") { TextEditor(text: $pair.to).frame(minHeight: 100) }
                if let problem { Section { Text(problem).foregroundStyle(.red) } }
            }.navigationTitle(kind == .snippets ? "Snippet" : "Replacement").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { problem = save(pair); if problem == nil { dismiss() } } }
                }
        }
    }
}
