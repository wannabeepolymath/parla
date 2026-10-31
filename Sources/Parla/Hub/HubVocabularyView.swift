import SwiftUI
import ParlaCore

/// Reachable from Hub → Dictionary; shares its load-error and debounced-save gate.
struct HubVocabularyView: View {
    @ObservedObject var model: HubModel
    @State private var sample = ""
    @State private var confirmReplace = false

    private var rules: [LiteralReplacement] {
        model.replacements.map { LiteralReplacement(source: $0.source, replacement: $0.replacement) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HubSection("Literal replacements", footer: "Case-sensitive whole words or phrases. Longest match wins at each position; row order breaks ties. Applied once after cleanup, or locally when cleanup is off or fails. Whole-utterance snippets stay locked. Empty list means off.") {
                ForEach($model.replacements) { $row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("Exact source", text: $row.source).hubField()
                            Button { model.replacements.removeAll { $0.id == row.id } } label: {
                                Image(systemName: "trash")
                            }.buttonStyle(.plain)
                        }
                        Text("Literal output (line breaks allowed)").font(.caption).foregroundStyle(Theme.muted)
                        TextEditor(text: $row.replacement).font(.system(size: 12)).frame(height: 48)
                    }.padding(12)
                    HubDivider()
                }
                if model.replacements.isEmpty { EmptyHint(text: "No replacement rules") }
            }
            Button("Add replacement") { model.replacements.append(.init()) }
                .buttonStyle(HubButtonStyle())
            TextField("Preview replacement input", text: $sample).hubField()
            Text(LiteralReplacement.apply(rules, to: sample))
                .font(.system(size: 12)).textSelection(.enabled)

            HubSection("Vocabulary files", footer: "Versioned JSON containing only words, snippets, and replacements. Merge keeps existing entries on conflict. Replace first saves a vocabulary-only backup beside settings.json.") {
                HStack {
                    Button("Import…") { model.chooseVocabularyImport() }
                    Button("Export…") { model.exportVocabulary() }
                }.buttonStyle(HubButtonStyle()).padding(12)
                if let preview = model.importPreview {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(preview.incoming.words.count) words · \(preview.incoming.snippets.count) snippets · \(preview.incoming.replacements.count) replacements")
                        Text("\(preview.conflicts) existing-key conflicts; \(preview.duplicateWords) duplicate words removed from import.")
                            .foregroundStyle(Theme.muted)
                        if !preview.conflictKeys.isEmpty {
                            ScrollView {
                                Text(preview.conflictKeys.joined(separator: "\n"))
                                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            }.frame(maxHeight: 100)
                        }
                        HStack {
                            Button("Merge — keep existing") { model.applyVocabulary(.merge) }
                            Button("Replace vocabulary…") { confirmReplace = true }
                                .disabled(preview.incoming.isEmpty)
                            Button("Cancel") { model.importPreview = nil }
                        }.buttonStyle(HubButtonStyle())
                    }.font(.system(size: 12)).padding(12)
                }
                if let message = model.transferMessage {
                    Text(message).font(.system(size: 12)).textSelection(.enabled).padding(12)
                }
            }
        }
        .alert("Replace all vocabulary?", isPresented: $confirmReplace) {
            Button("Cancel", role: .cancel) {}
            Button("Back up and replace", role: .destructive) { model.applyVocabulary(.replace) }
        } message: {
            Text("All current words, snippets, and replacement rules will be replaced by this import. Other settings are kept. A vocabulary-only backup must succeed first.")
        }
    }
}
