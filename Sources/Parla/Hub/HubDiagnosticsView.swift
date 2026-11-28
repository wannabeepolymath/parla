import SwiftUI
import ParlaCore

struct HubDiagnosticsView: View {
    @ObservedObject var model: HubModel
    var body: some View {
        HubSection("Diagnostics", footer: model.diagnosticMessage ?? "Kept in memory until you quit. Nothing is uploaded.") {
            HubRow("Recent activity", detail: "Timings and outcomes only. No text, audio or names.") {
                HStack(spacing: 8) {
                    Button("Clear") { model.clearDiagnostics() }.buttonStyle(HubButtonStyle())
                    Button("Review…") { model.prepareDiagnostics() }.buttonStyle(HubButtonStyle())
                }
            }
            if let data = model.diagnosticReview {
                HubDivider()
                VStack(alignment: .leading, spacing: 10) {
                    ScrollView([.horizontal, .vertical]) {
                        Text(String(decoding: data, as: UTF8.self)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 230)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
                    HStack(spacing: 8) {
                        Spacer()
                        Button("Close") { model.diagnosticReview = nil }.buttonStyle(HubButtonStyle())
                        Button("Export…") { model.exportDiagnostics() }.buttonStyle(HubButtonStyle(kind: .primary))
                    }
                }
                .hubInset()
            }
        }
    }
}
