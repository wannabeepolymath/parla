import SwiftUI
import ParlaCore

struct HistoryRetryReview: View {
    @ObservedObject var model: HubModel
    let preview: HistoryRetryPreview
    private var settingsBlocked: Bool { model.loadError != nil || model.saveError != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(preview.request.isSegmented ? "Experimental segmented Original — review" : "Retry original — review before request and save").font(.headline)
            Text("Preview stays in memory until quit or Discard. Nothing is inserted. History off permits preview/Copy; enable it to explicitly save the same result.")
                .font(.caption).foregroundStyle(Theme.muted)
            if let disclosure = preview.request.disclosure { Text(disclosure).font(.caption).textSelection(.enabled) }
            Text(preview.request.configuration.summary).font(.caption).textSelection(.enabled)
            if let review = preview.request.presetReview {
                Text(review).font(.caption).textSelection(.enabled)
            }
            Text("Historical app/site and original request settings: unknown. Preset metadata does not recover a spoken or saved instruction.")
                .font(.caption).foregroundStyle(Theme.muted)
            if let prior = preview.original.retries?.last {
                Text(prior.configuration == preview.request.configuration
                     ? "Safe recorded fields match the last saved retry. Credentials and endpoint paths are omitted; exact configuration equivalence is unknown."
                     : "Safe recorded fields differ from the last saved retry. Original request configuration remains unknown.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            version("Original", preview.original.raw) { model.copyHistoryRetryOriginal(preview.id) }
            version("Previous result", preview.original.best) { model.copyHistoryRetryPrevious(preview.id) }
            if let proposed = preview.proposed {
                version("Proposed result", proposed) { model.copyHistoryRetryProposed(preview.id) }
            }
            if let provenance = preview.provenance, let counts = provenance.segmented {
                Text("Actual: \(counts.attempted) attempts, \(counts.completed)/\(counts.planned) segments complete. "
                     + (provenance.configuration.executionKind == .deterministic ? "Whole-Original local rules only; zero requests. " : "")
                     + "Tokens are unknown unless every response reports valid usage; no cost estimate.")
                    .font(.caption)
            }
            if let model = preview.provenance?.usage?.cleanupModel {
                Text("Resolved provider model: \(model)").font(.caption)
            }
            Text(preview.status).font(.caption).foregroundStyle(Theme.muted)
            if preview.loading { ProgressView().controlSize(.small) }
            HStack {
                if !preview.started {
                    Button(preview.request.isSegmented ? "Start experimental cleanup" : preview.request.configuration.kind == .cleanup ? "Request Ordinary Cleanup" : "Apply Selected Preset to Original") {
                        Task { await model.startHistoryRetry(preview.id) }
                    }.disabled(settingsBlocked || preview.stale || model.history.loadBlocked)
                }
                if preview.proposed != nil, !preview.saved, !preview.stale {
                    Button(preview.saveFailed ? "Retry Save" : preview.request.isSegmented ? "Save reviewed result" : "Apply Result") { model.saveHistoryRetry(preview.id) }
                        .disabled(settingsBlocked || !model.settings.historyEnabled || model.history.loadBlocked)
                }
                if preview.started, !preview.stale, !preview.loading, !preview.request.isSegmented {
                    Button("Review New Request") {
                        model.prepareHistoryRetry(preview.id, applyPreset: preview.request.configuration.kind == .preset)
                    }.disabled(settingsBlocked || model.history.loadBlocked)
                }
                Button(preview.loading ? "Cancel and discard" : "Discard", role: .destructive) { model.discardHistoryRetry(preview.id) }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }

    private func version(_ title: String, _ text: String, copy: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title).font(.caption).foregroundStyle(Theme.muted); Spacer(); Button("Copy " + title, action: copy) }
            Text(text).font(.system(size: 13)).textSelection(.enabled)
        }
    }
}
