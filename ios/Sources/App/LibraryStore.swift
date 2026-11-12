import Foundation
import Combine
import ParlaCore

@MainActor final class LibraryStore: ObservableObject {
    @Published private(set) var library = Library()
    @Published var error: String?
    let root: URL
    private let file: ProtectedFile<Library>
    /// Same Application Support/Parla root as desktop, so ParlaCore's models directory sits inside it
    /// and inherits its backup exclusion. Settings live here too; nothing here is in the App Group.
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Parla", isDirectory: true)
        file = ProtectedFile(url: self.root.appendingPathComponent("library-v1.json"), initial: { Library() })
        do { try reload() } catch { self.error = "Could not read local data. Your existing data has not been overwritten." }
    }
    var audioDirectory: URL { root.appendingPathComponent("audio", isDirectory: true) }
    func audioURL(_ name: String) -> URL? {
        guard name == URL(fileURLWithPath: name).lastPathComponent, name.hasSuffix(".wav") else { return nil }
        return audioDirectory.appendingPathComponent(name)
    }
    func prepareDirectories() throws {
        for url in [root, audioDirectory] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var location = url; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try location.setResourceValues(values)
        }
    }
    func reload(now: Date = Date()) throws {
        try mutate(now: now) { _ in }
    }
    func mutate(now: Date = Date(), _ body: (inout Library) throws -> Void) throws {
        var obsolete: [String] = []
        let next = try file.transaction { state in
            let previous = state.transcripts.compactMap(\.audioName)
            try body(&state)
            state.transcripts.removeAll { !state.preferences.retention.retains($0.date, now: now) }
            let remaining = Set(state.transcripts.compactMap(\.audioName))
            obsolete = previous.filter { !remaining.contains($0) }
            return state
        }
        library = next
        for name in obsolete { if let url = audioURL(name) { try FileManager.default.removeItem(at: url) } }
    }
    func savePreferences(_ preferences: Preferences) throws {
        try mutate { $0.preferences = preferences }
        try sweepAudio()
    }
    func save(_ note: Note) throws {
        try mutate { state in
            if let index = state.notes.firstIndex(where: { $0.id == note.id }) { state.notes[index] = note }
            else { state.notes.insert(note, at: 0) }
        }
    }
    func deleteTranscript(_ id: UUID) throws { try mutate { $0.transcripts.removeAll { $0.id == id } } }
    func sweepAudio() throws {
        try prepareDirectories()
        let retained = Set(library.transcripts.compactMap(\.audioName))
        for url in try FileManager.default.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: nil)
        where !retained.contains(url.lastPathComponent) { try FileManager.default.removeItem(at: url) }
    }
    /// Settings encoding is credential-free by construction; audio and keys are never exported.
    func exportText(settings: Settings) -> String {
        struct Export: Encodable { let library: Library; let settings: Settings }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(Export(library: library, settings: settings))).flatMap { String(data: $0, encoding: .utf8) } ?? "Unable to export local data."
    }
}
