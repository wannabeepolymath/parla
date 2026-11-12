import ActivityKit
import Foundation

struct RecordingActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String
        var started: Date
        var words: Int
    }
    var sessionID: UUID
    var generation: UUID
}
