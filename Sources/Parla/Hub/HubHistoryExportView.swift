import SwiftUI
import ParlaCore

struct HistoryExportReview: View {
    @ObservedObject var model: HubModel
    let request: HistoryExportRequest
    @State private var content = TranscriptExport.Content.result
    @State private var format = TranscriptExport.Format.text

    var body: some View {
        HubSection("Export \(request.count) \(request.count == 1 ? "dictation" : "dictations")", footer: request.scope) {
            HubRow("Text") {
                Picker("Text", selection: $content) {
                    ForEach(TranscriptExport.Content.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).hubControl()
            }
            HubDivider()
            HubRow("File format") {
                Picker("File format", selection: $format) {
                    ForEach(TranscriptExport.Format.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.hubControl()
            }
            HubDivider()
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { model.historyExport = nil; model.historyExportMessage = nil }
                    .buttonStyle(HubButtonStyle())
                Button("Export…") { model.exportHistory(content: content, format: format) }
                    .buttonStyle(HubButtonStyle(kind: .primary))
            }
            .hubInset()
        }
    }
}
