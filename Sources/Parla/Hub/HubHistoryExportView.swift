import SwiftUI
import ParlaCore

struct HistoryExportReview: View {
    @ObservedObject var model: HubModel
    let request: HistoryExportRequest
    @State private var content = TranscriptExport.Content.result
    @State private var format = TranscriptExport.Format.text

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export \(request.count) saved \(request.count == 1 ? "entry" : "entries")").font(.headline)
            Text(request.scope + ". Uses the saved text captured when you opened this export. Unsaved results are excluded.")
                .font(.caption).foregroundStyle(Theme.muted)
            Picker("Text", selection: $content) {
                ForEach(TranscriptExport.Content.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Text("Result uses the saved result when available, otherwise the original.")
                .font(.caption).foregroundStyle(Theme.muted)
            Picker("File format", selection: $format) {
                ForEach(TranscriptExport.Format.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            HStack {
                Button("Choose File…") { model.exportHistory(content: content, format: format) }
                    .buttonStyle(HubButtonStyle(kind: .primary))
                Button("Cancel") { model.historyExport = nil; model.historyExportMessage = nil }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }
}
