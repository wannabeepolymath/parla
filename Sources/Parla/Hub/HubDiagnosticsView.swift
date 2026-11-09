import SwiftUI
import ParlaCore

struct HubDiagnosticsView: View {
    @ObservedObject var model: HubModel
    var body: some View {
        HubSection("Diagnostics", footer: "Kept in memory until you quit. Nothing is uploaded.") {
            HubRow("Recent activity", detail: "Timings and outcomes only. No text, audio or names.") {
                Button("Review") { model.prepareDiagnostics() }.buttonStyle(HubButtonStyle())
                Button("Clear") { model.clearDiagnostics() }.buttonStyle(HubButtonStyle(kind: .danger))
            }
            if let data = model.diagnosticReview {
                HubDivider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Diagnostics snapshot").font(.headline)
                    ScrollView([.horizontal, .vertical]) {
                        Text(String(decoding: data, as: UTF8.self)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 230)
                    HStack {
                        Button("Export…") { model.exportDiagnostics() }.buttonStyle(HubButtonStyle(kind: .primary))
                        Button("Close") { model.diagnosticReview = nil }
                    }
                }.padding(14)
            }
            if let message = model.diagnosticMessage {
                Text(message).font(.caption).foregroundStyle(Theme.muted).padding(14)
            }
        }
    }
}
