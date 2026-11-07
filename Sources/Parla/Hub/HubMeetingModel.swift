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
                return metadata?.chunks.contains(where: { $0.accepted != nil }) == true ? "Transcript saved. Raw audio deleted." : "Raw audio expired. Delete this meeting to start another."
            }
            if metadata?.unknownCoverage == true,metadata?.selections.contains(where: { $0.kind == .selectedApplication }) == true {
                if let metadata,let track = metadata.selections.firstIndex(where: { $0.kind == .selectedApplication }),
                   !metadata.chunks.contains(where: { $0.track == track }) {
                    return "Couldn't capture that app's audio. Check System Audio Recording access in System Settings and that the selected app is playing audio. Any saved microphone audio is kept."
                }
                return "Recording stopped early. Check System Audio Recording access in System Settings and that the selected app is playing audio. Any saved audio is kept; some audio may be missing."
            }
            if metadata?.unknownCoverage == true { return "Recording stopped early. Saved audio is available; some audio may be missing." }
            if metadata?.chunks.isEmpty == true { return "Recording stopped. No audio was saved." }
            if metadata?.chunks.contains(where:{$0.stage == .sealed}) != true { return "Recording stopped. There is not enough saved audio to transcribe." }
            return "Audio saved. Transcribe when you’re ready."
        case .transcribing: return "Transcribing saved audio…"
        case .deleting,.expired: return "Finishing deletion of saved audio and text…"
        case .unavailable: return "Saved meeting unavailable. Retry opening after storage work finishes."
        case .detached: return "Saved meeting closed. Open Meetings again to review saved audio."
        }
    }
}
