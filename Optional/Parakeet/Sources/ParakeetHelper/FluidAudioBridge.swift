import Foundation
import CoreML
import FluidAudio

/// The one admitted local API configuration. Requested units do not attest ANE use.
public struct LocalModelConfiguration: Equatable, Sendable {
    public let directory: URL
    public let version = "v3"
    public let precision = "int4"
    public let requestedCompute = "cpuAndNeuralEngine"
    public let lowPrecisionAccumulation = true
    public let parallelChunkConcurrency = 1
    public let encoderComputeOverride: String? = nil
    public init(directory: URL) { self.directory = directory }
}

/// Only model/session IO is replaceable; the driver and helper runner stay real.
public protocol LocalASRSession: Sendable {
    func transcribe(_ samples: [Float], filter: String?) async throws -> String
    func cleanup() async
}

public struct FluidAudioDriver: Sendable {
    public var open: @Sendable (LocalModelConfiguration) async throws -> any LocalASRSession
    public init(open: @escaping @Sendable (LocalModelConfiguration) async throws -> any LocalASRSession = NativeLocalSession.open) {
        self.open = open
    }

    public func run(directory: URL, samples: [Float]?, filter: String?) async throws -> String {
        let session = try await open(LocalModelConfiguration(directory: directory))
        do {
            try Task.checkCancellation()
            let text = try await samples.mapAsync { try await session.transcribe($0, filter: filter) } ?? ""
            await session.cleanup()
            return text
        } catch {
            // Cancellation cannot retire native ownership before the awaited call returns.
            await session.cleanup()
            throw error
        }
    }
}

private extension Optional where Wrapped == [Float] {
    func mapAsync(_ transform: ([Float]) async throws -> String) async rethrows -> String? {
        guard let samples = self else { return nil }
        return try await transform(samples)
    }
}

/// This implementation is compiled by the optional package's own fake-only tests.
/// Tests never construct it or any CoreML object. There is no canImport fallback.
public actor NativeLocalSession: LocalASRSession {
    private let manager: AsrManager
    private init(manager: AsrManager) { self.manager = manager }

    public static func open(_ configuration: LocalModelConfiguration) async throws -> any LocalASRSession {
        ModelHub.offlineMode = true
        AppLogger.mirrorsToConsole = false
        AppLogger.minimumLevel = .fault
        let ml = MLModelConfiguration()
        ml.computeUnits = .cpuAndNeuralEngine
        ml.allowLowPrecisionAccumulationOnGPU = true
        let models = try AsrModels.loadLocal(from: configuration.directory, version: .v3,
            configuration: ml, encoderPrecision: .int4, encoderComputeUnits: nil)
        let manager = AsrManager(config: ASRConfig(parallelChunkConcurrency: 1), models: models)
        return NativeLocalSession(manager: manager)
    }

    public func transcribe(_ samples: [Float], filter: String?) async throws -> String {
        let language = filter.flatMap(Language.init(rawValue:))
        var state = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(samples, decoderState: &state, language: language).text
    }

    public func cleanup() async { await manager.cleanup() }
}
