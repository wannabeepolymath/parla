import SwiftUI
import ParlaCore

struct HistoryRetryReview: View {
    @ObservedObject var model: HubModel
    let preview: HistoryRetryPreview
    private var settingsBlocked: Bool { model.loadError != nil || model.saveError != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(preview.request.isSegmented ? "Clean up in sections" : preview.request.configuration.kind == .cleanup ? "Clean up again" : "Apply preset").font(.headline)
            Text("Nothing is typed. Save the result to replace it in History.")
                .font(.caption).foregroundStyle(Theme.muted)
            if let disclosure = preview.request.disclosure { Text(disclosure).font(.caption).textSelection(.enabled) }
            Text(preview.request.configuration.summary).font(.caption).textSelection(.enabled)
            if let review = preview.request.presetReview {
                Text(review).font(.caption).textSelection(.enabled)
            }
            if let prior = preview.original.retries?.last, prior.configuration == preview.request.configuration {
                Text("These are the same settings as the last time you did this.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            version("Original", preview.original.raw) { model.copyHistoryRetryOriginal(preview.id) }
            version("Previous result", preview.original.best) { model.copyHistoryRetryPrevious(preview.id) }
            if let proposed = preview.proposed {
                version("New result", proposed) { model.copyHistoryRetryProposed(preview.id) }
            }
            if let provenance = preview.provenance, let counts = provenance.segmented {
                Text("\(counts.completed) of \(counts.planned) sections done"
                     + (provenance.configuration.executionKind == .deterministic ? " · no online requests" : ""))
                    .font(.caption)
            }
            // ponytail: segmented runs store a placeholder, not a model name; show nothing then.
            if let model = preview.provenance?.usage?.cleanupModel, !model.contains("usage") {
                Text("Model: \(model)").font(.caption)
            }
            Text(preview.status).font(.caption).foregroundStyle(Theme.muted)
            if preview.loading { ProgressView().controlSize(.small) }
            HStack {
                if !preview.started {
                    Button(preview.request.isSegmented || preview.request.configuration.kind == .cleanup ? "Clean up" : "Apply preset") {
                        Task { await model.startHistoryRetry(preview.id) }
                    }.disabled(settingsBlocked || preview.stale || model.history.loadBlocked)
                }
                if preview.proposed != nil, !preview.saved, !preview.stale {
                    Button(preview.saveFailed ? "Try saving again" : "Save result") { model.saveHistoryRetry(preview.id) }
                        .disabled(settingsBlocked || !model.settings.historyEnabled || model.history.loadBlocked)
                }
                if preview.started, !preview.stale, !preview.loading, !preview.request.isSegmented {
                    Button("Try again") {
                        model.prepareHistoryRetry(preview.id, applyPreset: preview.request.configuration.kind == .preset)
                    }.disabled(settingsBlocked || model.history.loadBlocked)
                }
                Button(preview.loading ? "Cancel" : "Discard", role: .destructive) { model.discardHistoryRetry(preview.id) }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }

    private func version(_ title: String, _ text: String, copy: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title).font(.caption).foregroundStyle(Theme.muted); Spacer(); Button("Copy", action: copy) }
            Text(text).font(.system(size: 13)).textSelection(.enabled)
        }
    }
}
