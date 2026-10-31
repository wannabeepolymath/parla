import AppKit
import Darwin
import ParlaCore
import UniformTypeIdentifiers

struct HistoryExportRequest {
    let scope: String
    let original: TranscriptExport
    let result: TranscriptExport
    var count: Int { original.entries.count }

    init(scope: String, entries: [HistoryEntry]) {
        self.scope = scope
        original = TranscriptExport(entries: entries.map { .init(text: $0.raw, date: $0.date, appLabel: $0.appName) })
        result = TranscriptExport(entries: entries.map { .init(text: $0.best, date: $0.date, appLabel: $0.appName) })
    }
}

struct HistoryExportSaveRequest {
    let filename: String
    let format: TranscriptExport.Format
    var contentType: UTType {
        format == .text ? .plainText : (UTType(filenameExtension: "md") ?? .plainText)
    }
    static func select(_ request: Self) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [request.contentType]
        panel.nameFieldStringValue = request.filename
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Validated after the panel returns, before even an injected writer runs.
/// Protect the actual injected paths and both lexical and resolved aliases.
enum HistoryExportDestination {
    enum Refusal: Error { case protectedPath, extensionMismatch, savedStorage }

    static func validate(_ destination: URL, format: TranscriptExport.Format,
                         settings: URL, history: URL, recordings: URL) throws {
        try validate(destination, fileExtension: format.fileExtension, settings: settings, history: history, recordings: recordings)
    }

    static func validate(_ destination: URL, fileExtension: String,
                         settings: URL, history: URL, recordings: URL, protectedFiles: [URL] = [], saved: SavedAudioImportStore.Protection? = nil, transient: SavedAudioImportStorage.Identity? = nil) throws {
        guard destination.isFileURL, destination.host == nil || destination.host == "" || destination.host == "localhost",
              destination.query == nil, destination.fragment == nil, !destination.path.utf8.contains(0) else { throw Refusal.protectedPath }
        let paths = [destination.standardizedFileURL, try resolved(destination)]
        func within(_ url: URL, _ root: URL) -> Bool {
            let path = url.pathComponents, prefix = root.pathComponents
            return path.starts(with: prefix)
        }
        let savedFiles = saved?.files ?? []
        let protectedIdentities = (saved?.identities ?? []).union(transient.map { [$0] } ?? [])
        for path in paths {
            var info = stat()
            if lstat(path.path,&info) == 0 {
                if protectedIdentities.contains(.init(device:info.st_dev,inode:info.st_ino)) { throw Refusal.protectedPath }
            } else if errno != ENOENT && errno != ENOTDIR { throw Refusal.protectedPath }
        }
        let files = try ([settings, history] + protectedFiles + savedFiles).flatMap { [$0.standardizedFileURL, try resolved($0)] }
        let recordingRoot = try resolved(recordings)
        var directories = [recordings.standardizedFileURL, recordingRoot]
        if let root = saved?.root { directories += [root.standardizedFileURL, try resolved(root)] }
        // RecordingStore writes audio and sidecars directly into this folder.
        // Also protect outward symlinks already in it, so selecting their target
        // cannot replace a live recording through another spelling.
        do {
            directories += try FileManager.default.contentsOfDirectory(at: recordingRoot, includingPropertiesForKeys: nil)
                .map { try resolved($0) }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // The recording folder need not exist yet.
        }
        guard !paths.contains(where: { path in files.contains(path) || directories.contains(where: { within(path, $0) }) }) else {
            throw Refusal.protectedPath
        }
        guard destination.pathExtension.lowercased() == fileExtension else { throw Refusal.extensionMismatch }
    }

    private static func resolved(_ url: URL) throws -> URL {
        // Foundation can leave the whole path unresolved when its final file
        // doesn't exist. Resolve the existing ancestor, then restore new names.
        // Follow dangling aliases too: settings/history may not exist yet.
        var ancestor = url
        var suffix: [String] = []
        var links = 0
        while ancestor.path != "/", !FileManager.default.fileExists(atPath: ancestor.path) {
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path) {
                links += 1
                guard links <= 40 else { throw Refusal.protectedPath }
                ancestor = URL(fileURLWithPath: target, relativeTo: ancestor.deletingLastPathComponent()).absoluteURL
            } else {
                suffix.append(ancestor.lastPathComponent)
                ancestor.deleteLastPathComponent()
            }
        }
        return suffix.reversed().reduce(ancestor.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.standardizedFileURL
    }
}

extension HubModel {
    /// Bounded metadata projection only. No payload, hash, setup or tree inventory.
    func validateExportDestination(_ url: URL, fileExtension: String, protectedFiles: [URL] = []) throws {
        let projection: SavedAudioImportStore.Protection?
        do { projection = try savedAudioImport?.protection() }
        catch { throw HistoryExportDestination.Refusal.savedStorage }
        let source = audioImport.source ?? audioImport.job?.source ?? savedAudioImport?.job?.source
        try HistoryExportDestination.validate(url,fileExtension:fileExtension,settings:store.url,history:history.url,
            recordings:recordingDirectory,protectedFiles:protectedFiles + (source.map { [$0.originalURL] } ?? []),
            saved:projection,transient:source?.originalIdentity)
        if let projection {
            do {try savedAudioImport?.store.validateProtection(projection)}
            catch {throw HistoryExportDestination.Refusal.savedStorage}
        }
    }

    func prepareHistoryExport(rowID: UUID) {
        guard let entry = history.entries.first(where: { $0.id == rowID }) else {
            historyExport = nil
            historyExportMessage = "This saved entry is no longer available."
            return
        }
        historyExportMessage = nil
        historyExport = HistoryExportRequest(scope: "Saved entry", entries: [entry])
    }

    func prepareFilteredHistoryExport(_ query: String) {
        // Refresh the saved projection only; no settings load/save or history
        // reload/trim is necessary for this read-only action.
        refreshHistory()
        let entries = filteredHistory(query)
        historyExportMessage = entries.isEmpty ? "No saved entries match this search." : nil
        historyExport = entries.isEmpty ? nil : HistoryExportRequest(scope: "All saved entries matching the current search", entries: entries)
    }

    func exportHistory(content: TranscriptExport.Content, format: TranscriptExport.Format) {
        guard let request = historyExport else { return }
        let document = content == .original ? request.original : request.result
        let data = document.encoded(content: content, format: format)
        let selection = HistoryExportSaveRequest(filename: format.suggestedFilename(now: historyExportClock()), format: format)
        historyExportMessage = nil
        guard let url = historyExportPanel(selection) else { return }
        do {
            try validateExportDestination(url, fileExtension: format.fileExtension)
            try historyExportWriter(data, url)
            historyExportMessage = "Exported \(request.count) saved \(request.count == 1 ? "entry" : "entries") · \(content.rawValue) · \(format.rawValue)."
            historyExport = nil
        } catch HistoryExportDestination.Refusal.savedStorage {
            historyExportMessage = "Saved storage cannot supply complete protection. Retry export after storage is available."
        } catch HistoryExportDestination.Refusal.protectedPath {
            historyExportMessage = "Choose a file outside Parla’s settings, history and recording files."
        } catch HistoryExportDestination.Refusal.extensionMismatch {
            historyExportMessage = "Choose a filename ending in .\(format.fileExtension)."
        } catch {
            // Filesystem errors can contain private paths. Keep them out of the
            // transcript and user-facing status, just like provider errors.
            historyExportMessage = "Couldn’t export \(request.count) saved \(request.count == 1 ? "entry" : "entries") · \(content.rawValue) · \(format.rawValue). Choose a writable location and try again."
        }
    }
}
