import Foundation

enum RetentionPolicy: String, Codable, CaseIterable, Identifiable {
    case keep, day, never
    var id: String { rawValue }
    var title: String { switch self { case .keep: "Keep"; case .day: "24 hours"; case .never: "Never" } }
    func retains(_ date: Date, now: Date) -> Bool {
        self == .keep || (self == .day && date > now.addingTimeInterval(-86_400))
    }
}
struct Preferences: Codable, Equatable {
    var onboarded = false
    var retention: RetentionPolicy = .keep
    var feedback = true
    var microphoneID: String?
}
struct Transcript: Identifiable, Codable, Equatable {
    var id = UUID()
    var date = Date()
    var raw = ""
    var cleaned: String?
    var final: String?
    var duration: TimeInterval = 0
    var audioName: String?
    var error: String?
    var text: String { final ?? cleaned ?? raw }
    var words: Int { text.split(whereSeparator: \.isWhitespace).count }
}
struct Note: Identifiable, Codable, Equatable {
    var id = UUID()
    var date = Date()
    var text = ""
}
struct Library: Codable, Equatable {
    var preferences = Preferences()
    var transcripts: [Transcript] = []
    var notes: [Note] = []
}
enum ParlaError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): text } }
    static let unavailable = ParlaError.message("Open Parla to continue. The app must be active to start the microphone.")
}
