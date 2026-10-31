import AppKit
import ParlaCore
import UniformTypeIdentifiers

struct DiagnosticSaveRequest {
    let filename = "parla-diagnostics.json"
    let contentType = UTType.json
    static func select(_ request: Self) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [request.contentType]
        panel.nameFieldStringValue = request.filename
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}

extension HubModel {
    func prepareDiagnostics() {
        do {
            diagnosticReview = try diagnostics.snapshot().encoded()
            diagnosticMessage = nil
        } catch { diagnosticMessage = "Couldn’t prepare diagnostics. Clear and try again." }
    }
    func clearDiagnostics() {
        diagnostics.clear()
        diagnosticReview = nil
        diagnosticMessage = "Diagnostics cleared from memory. Existing exported files are unchanged."
    }
    func exportDiagnostics() {
        guard let frozen = diagnosticReview else { return }
        diagnosticMessage = nil
        guard let destination = diagnosticPanel(DiagnosticSaveRequest()) else { return }
        do {
            try validateExportDestination(destination, fileExtension: "json")
            try diagnosticWriter(frozen, destination)
            diagnosticMessage = "Diagnostics exported."
            diagnosticReview = nil
        } catch HistoryExportDestination.Refusal.savedStorage {
            diagnosticMessage = "Saved storage cannot supply complete protection. Retry export after storage is available."
        } catch HistoryExportDestination.Refusal.protectedPath {
            diagnosticMessage = "Choose a file outside Parla’s settings, history and recording files."
        } catch HistoryExportDestination.Refusal.extensionMismatch {
            diagnosticMessage = "Choose a filename ending in .json."
        } catch {
            diagnosticMessage = "Couldn’t export diagnostics. Choose a writable location and retry this same review."
        }
    }
}
