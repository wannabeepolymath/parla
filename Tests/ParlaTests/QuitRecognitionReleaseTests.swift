import XCTest
@testable import Parla
@testable import ParlaCore

/// willTerminate must free the resident whisper context before exit(): ggml's
/// Metal device destructor aborts if a context is still alive then.
final class QuitRecognitionReleaseTests: XCTestCase {
    private final class Native: WhisperNativeContext {
        let freed: () -> Void
        init(_ freed: @escaping () -> Void) { self.freed = freed }
        deinit { freed() }
        var multilingual: Bool { false }
        func knowsLanguage(_ code: String) -> Bool { true }
        func spokenLanguage() -> String? { nil }
        func decode(_ samples: [Float], initialPrompt: String?, language: String,
                    configuration: WhisperDecodeConfiguration, shouldAbort: (() -> Bool)?) -> WhisperNativeDecode {
            WhisperNativeDecode(status: 0, segments: [])
        }
    }

    func testReleaseRunsAfterDrainAndBeforeReturn() throws {
        var frees = 0, drained = false
        var resident: WhisperTranscriber? = try WhisperTranscriber(modelPath: "/m", native: Native { frees += 1 })
        let chain = Task { try? await Task.sleep(nanoseconds: 50_000_000); drained = true }
        XCTAssertTrue(AppDelegate.releaseAfterDrain(chain) { resident = nil })
        XCTAssertTrue(drained); XCTAssertNil(resident); XCTAssertEqual(frees, 1)
    }

    func testUndrainedChainSkipsReleaseInsteadOfBlocking() throws {
        var frees = 0
        var resident: WhisperTranscriber? = try WhisperTranscriber(modelPath: "/m", native: Native { frees += 1 })
        let chain = Task<Void, Never> { try? await Task.sleep(nanoseconds: 5_000_000_000) }
        defer { chain.cancel() }
        XCTAssertFalse(AppDelegate.releaseAfterDrain(chain, timeout: 0.05) { resident = nil })
        XCTAssertNotNil(resident); XCTAssertEqual(frees, 0)
    }
}
