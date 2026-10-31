import SwiftUI
import ParlaCore

struct HubDiagnosticsView: View {
    @ObservedObject var model: HubModel
    var body: some View {
        HubSection("Diagnostics", footer: "Kept only in memory until Clear or quit, independently of History. Up to 64 recent operations within 128 KiB, including active work. No automatic upload or diagnostic disk log. Custom model labels are unavailable. Posted input is not confirmed insertion.") {
            HubRow("Review diagnostics", detail: "Stage timings and typed outcomes only. Energy/activity shadow suggestions are NOT APPLIED; accuracy is unqualified and energy is not speech proof. Speculative preview status, request count and timings are separate from final ASR. No text, audio, keys, endpoint, app or device names.") {
                Button("Prepare Review") { model.prepareDiagnostics() }.buttonStyle(HubButtonStyle())
                Button("Clear RAM") { model.clearDiagnostics() }.buttonStyle(HubButtonStyle(kind: .danger))
            }
            if let data = model.diagnosticReview {
                HubDivider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Frozen JSON review").font(.headline)
                    Text("New operations are excluded from this snapshot. Review locally before choosing Export.")
                        .font(.caption).foregroundStyle(Theme.muted)
                    ScrollView([.horizontal, .vertical]) {
                        Text(String(decoding: data, as: UTF8.self)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 230)
                    HStack {
                        Button("Export JSON…") { model.exportDiagnostics() }.buttonStyle(HubButtonStyle(kind: .primary))
                        Button("Close Review") { model.diagnosticReview = nil }
                    }
                }.padding(14)
            }
            if let message = model.diagnosticMessage {
                Text(message).font(.caption).foregroundStyle(Theme.muted).padding(14)
            }
        }
    }
}
