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
        } catch { diagnosticMessage = "Couldn’t show diagnostics. Clear them and try again." }
    }
    func clearDiagnostics() {
        diagnostics.clear()
        diagnosticReview = nil
        diagnosticMessage = "Diagnostics cleared."
    }
    func exportDiagnostics() {
        guard let frozen = diagnosticReview else { return }
        diagnosticMessage = nil
        guard let destination = diagnosticPanel(DiagnosticSaveRequest()) else { return }
        do {
            try withValidatedExportDestination(destination,fileExtension:"json") { try diagnosticWriter(frozen,destination) }
            diagnosticMessage = "Diagnostics exported."
            diagnosticReview = nil
        } catch HistoryExportDestination.Refusal.savedStorage {
            diagnosticMessage = "Couldn’t export because storage isn’t available. Try again."
        } catch HistoryExportDestination.Refusal.protectedPath {
            diagnosticMessage = "Choose a different file name or folder."
        } catch HistoryExportDestination.Refusal.extensionMismatch {
            diagnosticMessage = "Choose a filename ending in .json."
        } catch {
            diagnosticMessage = "Couldn’t export. Choose another location and try again."
        }
    }
}
