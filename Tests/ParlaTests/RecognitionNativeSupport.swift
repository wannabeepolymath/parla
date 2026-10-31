import Foundation
import ParlaCore

/// Only the bottom native context is fake; every caller keeps the default factory and Whisper adapter.
final class FoundationNativeProbe: @unchecked Sendable {
    struct Call { let samples: [Float]; let prompt: String?; let language: String; let instance: Int }
    var multilingual = true
    var outputs = [WhisperNativeDecode(status: 0, segments: ["native original"])]
    var calls: [Call] = []
    var paths: [String] = []
    var releases = 0, admissions = 0, metadataReads = 0
    var live = 0, peakLive = 0
    var events: [String] = []
    var detectedLanguage: String?
    var retainSamples = true
    var sampleCounts: [Int] = []
    var generation = RecognitionFileGeneration(bytes: 8, modified: 1)
    var runtime = RecognitionRuntime(nativeVersion: "fixture", buildScope: "fixture-build")
    var construct: (() -> Void)?, decode: (() -> Void)?
    var admission: ((String, RecognitionAdmission) throws -> Void)?
    func factory() -> RecognitionFactory {
        RecognitionFactory(native: { path, compute in
            self.paths.append(path); self.events.append("construct:\(self.paths.count)"); self.construct?(); return Native(self)
        }, runtime: { self.runtime }, metadata: { _ in self.metadataReads += 1; return self.generation },
        directory: URL(fileURLWithPath: "/owned"), admit: { path, policy in
            self.admissions += 1; try self.admission?(path, policy)
        })
    }
    final class Native: WhisperNativeContext {
        let state: FoundationNativeProbe
        let instance: Int
        init(_ state: FoundationNativeProbe) {
            self.state = state; instance = state.paths.count
            state.live += 1; state.peakLive = max(state.peakLive, state.live)
        }
        deinit { state.releases += 1; state.live -= 1; state.events.append("release:\(instance)") }
        var multilingual: Bool { state.multilingual }
        func knowsLanguage(_ code: String) -> Bool { ["en", "hi", "es"].contains(code) }
        func spokenLanguage() -> String? { state.detectedLanguage }
        func decode(_ samples: [Float], initialPrompt: String?, language: String,
                    configuration: WhisperDecodeConfiguration, shouldAbort: (() -> Bool)?) -> WhisperNativeDecode {
            state.sampleCounts.append(samples.count)
            state.calls.append(.init(samples: state.retainSamples ? samples : [], prompt: initialPrompt, language: language, instance: instance))
            state.decode?()
            return state.outputs.count > 1 ? state.outputs.removeFirst() : state.outputs[0]
        }
    }
}

func recordWave4BFixture(_ root: URL, _ action: String) throws {
    guard let path = ProcessInfo.processInfo.environment["PARLA_TEST_FIXTURE_MANIFEST"] else { return }
    let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); defer { try? file.close() }
    try file.seekToEnd()
    try file.write(contentsOf: Data("\(action)\t\(ProcessInfo.processInfo.processIdentifier)\t\(root.path)\n".utf8))
}
