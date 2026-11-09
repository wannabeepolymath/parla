import Foundation
import ParlaCore

/// Cached presentation only. Body never opens storage, authorization, devices or models.
struct HubMeetingModel {
    var state = MeetingSessionOwner.State.idle
    var metadata: MeetingSessionStore.Metadata?
    var captureAvailable = false, busy = false, captureOwned = false, recoveryDeleteAvailable = false
    var source = "Saved microphone", message: String?, text: String?
    var stoppingAvailable: Bool { captureOwned || state == .starting || state == .recording || state == .stopping }
    var canStart: Bool { captureAvailable && !busy && metadata == nil && state == .idle }
    var canTranscribe: Bool { !busy && state == .stopped && metadata?.expired == false && metadata?.unavailable == false && metadata?.chunks.contains { $0.stage == .sealed && !$0.audioRemoved && $0.accepted == nil } == true }
    var canRead: Bool { !busy && state == .stopped && metadata?.chunks.contains { $0.accepted != nil } == true && metadata?.expired == false }
    var status: String {
        if let message { return message }
        switch state {
        case .idle: return captureAvailable ? "Ready to record a meeting." : "Microphone recording is unavailable in this version. Saved meetings remain available."
        case .starting: return "Starting recording…"
        case .recording: return "Recording · " + source
        case .stopping: return "Finishing saved audio…"
        case .stopped:
            if metadata?.chunks.isEmpty == false,metadata?.chunks.allSatisfy(\.audioRemoved) == true {
                return metadata?.chunks.contains(where: { $0.accepted != nil }) == true ? "Transcript saved. Audio deleted." : "Audio expired. Delete this meeting to record another."
            }
            if metadata?.unknownCoverage == true,metadata?.selections.contains(where: { $0.kind == .selectedApplication }) == true {
                if let metadata,let track = metadata.selections.firstIndex(where: { $0.kind == .selectedApplication }),
                   !metadata.chunks.contains(where: { $0.track == track }) {
                    return "Couldn't record that app. Check System Audio Recording access and that the app is playing sound."
                }
                return "Recording stopped early. Check System Audio Recording access. Saved audio is kept."
            }
            if metadata?.unknownCoverage == true { return "Recording stopped early. Saved audio is kept." }
            if metadata?.chunks.isEmpty == true { return "Recording stopped. No audio was saved." }
            if metadata?.chunks.contains(where:{$0.stage == .sealed}) != true { return "Recording stopped. There is not enough saved audio to transcribe." }
            return "Audio saved. Transcribe when you’re ready."
        case .transcribing: return "Transcribing saved audio…"
        case .deleting,.expired: return "Deleting…"
        case .unavailable: return "Couldn't open the saved meeting. Try again in a moment."
        case .detached: return "Meeting closed. Open Meetings again to see it."
        }
    }
}
