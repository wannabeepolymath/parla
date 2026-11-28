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
        VStack(alignment: .leading, spacing: HubLayout.sectionSpacing) {
            HubSection("Replacements", footer: "Swaps exact words or phrases after dictation. Matching is case-sensitive.",
                       accessory: { HubAddButton("Add Replacement") { model.replacements.append(.init()) } }) {
                if model.replacements.isEmpty {
                    EmptyHint(text: model.loadError == nil ? "No replacements yet" : "Replacements can’t be shown",
                              detail: model.loadError == nil ? "Replace a word you say with the text you want, like “k8s” → “Kubernetes”."
                                                             : "They’ll appear once settings.json is fixed.")
                    HubDivider()
                } else {
                    MappingHeader(from: "Replace", to: "With")
                    ForEach($model.replacements) { $row in
                        MappingRow(from: $row.source, to: $row.replacement, fromPrompt: "Word or phrase", toPrompt: "Replacement",
                                   deleteLabel: "Delete replacement") { model.replacements.removeAll { $0.id == row.id } }
                        HubDivider()
                    }
                }
                HubRow("Try it", detail: sample.isEmpty ? "Type a sentence to preview replacements" : LiteralReplacement.apply(rules, to: sample)) {
                    TextField("Try a sentence", text: $sample, prompt: Text("Type a sentence")).hubField().hubControl()
                }
            }

            HubSection("Import and export", footer: model.transferMessage) {
                HubRow("Words, snippets and replacements", detail: "Share them as a file or bring in someone else’s") {
                    HStack(spacing: 8) {
                        Button("Import…") { model.chooseVocabularyImport() }
                        Button("Export…") { model.exportVocabulary() }
                    }.buttonStyle(HubButtonStyle())
                }
                if let preview = model.importPreview {
                    HubDivider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(preview.incoming.words.count) words · \(preview.incoming.snippets.count) snippets · \(preview.incoming.replacements.count) replacements")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                        Text("\(preview.conflicts) already exist · \(preview.duplicateWords) duplicates skipped")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        if !preview.conflictKeys.isEmpty {
                            ScrollView {
                                Text(preview.conflictKeys.joined(separator: "\n"))
                                    .font(.system(size: 12))
                                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            }.frame(maxHeight: 100)
                        }
                        HStack(spacing: 8) {
                            Button("Replace Mine…") { confirmReplace = true }
                                .buttonStyle(HubButtonStyle(kind: .danger))
                                .disabled(preview.incoming.isEmpty)
                            Spacer()
                            Button("Cancel") { model.importPreview = nil }.buttonStyle(HubButtonStyle())
                            Button("Add to Mine") { model.applyVocabulary(.merge) }.buttonStyle(HubButtonStyle(kind: .primary))
                        }
                    }
                    .hubInset()
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
