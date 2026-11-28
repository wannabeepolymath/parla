import SwiftUI
import ParlaCore

struct HistoryRetryReview: View {
    @ObservedObject var model: HubModel
    let preview: HistoryRetryPreview
    private var settingsBlocked: Bool { model.loadError != nil || model.saveError != nil }

    private var title: String {
        preview.request.isSegmented ? "Clean up in sections" : preview.request.configuration.kind == .cleanup ? "Clean up again" : "Apply preset"
    }

    var body: some View {
        HubSection(title, footer: "Nothing is typed. Save the result to replace it in History.") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if let disclosure = preview.request.disclosure { caption(disclosure) }
                    caption(preview.request.configuration.summary)
                    if let review = preview.request.presetReview { caption(review) }
                    if let prior = preview.original.retries?.last, prior.configuration == preview.request.configuration {
                        caption("These are the same settings as last time.")
                    }
                }
                version("Original", preview.original.raw) { model.copyHistoryRetryOriginal(preview.id) }
                version("Previous result", preview.original.best) { model.copyHistoryRetryPrevious(preview.id) }
                if let proposed = preview.proposed {
                    version("New result", proposed) { model.copyHistoryRetryProposed(preview.id) }
                }
                HStack(spacing: 6) {
                    if preview.loading { ProgressView().controlSize(.small) }
                    caption(statusLine)
                }
                HStack(spacing: 8) {
                    Button(preview.loading ? "Cancel" : "Discard", role: .destructive) { model.discardHistoryRetry(preview.id) }
                        .buttonStyle(HubButtonStyle())
                    Spacer()
                    if preview.started, !preview.stale, !preview.loading, !preview.request.isSegmented {
                        Button("Try Again") {
                            model.prepareHistoryRetry(preview.id, applyPreset: preview.request.configuration.kind == .preset)
                        }
                        .buttonStyle(HubButtonStyle())
                        .disabled(settingsBlocked || model.history.loadBlocked)
                    }
                    if !preview.started {
                        Button(preview.request.isSegmented || preview.request.configuration.kind == .cleanup ? "Clean Up" : "Apply Preset") {
                            Task { await model.startHistoryRetry(preview.id) }
                        }
                        .buttonStyle(HubButtonStyle(kind: .primary))
                        .disabled(settingsBlocked || preview.stale || model.history.loadBlocked)
                    }
                    if preview.proposed != nil, !preview.saved, !preview.stale {
                        Button(preview.saveFailed ? "Try Saving Again" : "Save Result") { model.saveHistoryRetry(preview.id) }
                            .buttonStyle(HubButtonStyle(kind: .primary))
                            .disabled(settingsBlocked || !model.settings.historyEnabled || model.history.loadBlocked)
                    }
                }
            }
            .hubInset()
        }
    }

    /// Progress, model and status on one quiet line.
    private var statusLine: String {
        var parts: [String] = []
        if let provenance = preview.provenance, let counts = provenance.segmented {
            parts.append("\(counts.completed) of \(counts.planned) sections done"
                         + (provenance.configuration.executionKind == .deterministic ? " · no online requests" : ""))
        }
        // ponytail: segmented runs store a placeholder, not a model name; show nothing then.
        if let model = preview.provenance?.usage?.cleanupModel, !model.contains("usage") { parts.append("Model: \(model)") }
        parts.append(preview.status)
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.muted).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func version(_ title: String, _ text: String, copy: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                Spacer()
                Button("Copy", action: copy).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent)
            }
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.text).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
