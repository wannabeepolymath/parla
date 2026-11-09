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
            HubSection("Replacements", footer: "Swap exact words or phrases after dictation. Matching is case-sensitive.") {
                ForEach($model.replacements) { $row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("Replace", text: $row.source).hubField()
                            Button { model.replacements.removeAll { $0.id == row.id } } label: {
                                Image(systemName: "trash")
                            }.buttonStyle(.plain)
                        }
                        Text("With").font(.caption).foregroundStyle(Theme.muted)
                        TextEditor(text: $row.replacement).font(.system(size: 12)).frame(height: 48)
                    }.padding(12)
                    HubDivider()
                }
                if model.replacements.isEmpty { EmptyHint(text: "No replacements yet") }
            }
            Button("Add replacement") { model.replacements.append(.init()) }
                .buttonStyle(HubButtonStyle())
            TextField("Try a sentence", text: $sample).hubField()
            Text(LiteralReplacement.apply(rules, to: sample))
                .font(.system(size: 12)).textSelection(.enabled)

            HubSection("Import and export", footer: "Share your words, snippets and replacements as a file.") {
                HStack {
                    Button("Import…") { model.chooseVocabularyImport() }
                    Button("Export…") { model.exportVocabulary() }
                }.buttonStyle(HubButtonStyle()).padding(12)
                if let preview = model.importPreview {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(preview.incoming.words.count) words · \(preview.incoming.snippets.count) snippets · \(preview.incoming.replacements.count) replacements")
                        Text("\(preview.conflicts) already exist · \(preview.duplicateWords) duplicates skipped")
                            .foregroundStyle(Theme.muted)
                        if !preview.conflictKeys.isEmpty {
                            ScrollView {
                                Text(preview.conflictKeys.joined(separator: "\n"))
                                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            }.frame(maxHeight: 100)
                        }
                        HStack {
                            Button("Add to mine") { model.applyVocabulary(.merge) }
                            Button("Replace mine…") { confirmReplace = true }
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
        .alert("Replace your words, snippets and replacements?", isPresented: $confirmReplace) {
            Button("Cancel", role: .cancel) {}
            Button("Replace", role: .destructive) { model.applyVocabulary(.replace) }
        } message: {
            Text("Parla saves a backup first. Other settings aren’t changed.")
        }
    }
}
