import Foundation

/// Exact finalized ASR, separate from prepared delivery text. Not a receipt or
/// persisted record. Only ordinary, non-live keyboard dictation emits it.
public struct OriginalDictationContext: Equatable, Sendable {
    public static let maximumBytes = 64 * 1024
    public let raw: String
    public let generation: Int
    public let operationID: UUID

    public init?(raw: String, generation: Int, operationID: UUID, maximumBytes: Int = Self.maximumBytes) {
        guard !raw.isEmpty, raw.utf8.count <= maximumBytes else { return nil }
        self.raw = raw; self.generation = generation; self.operationID = operationID
    }
}
