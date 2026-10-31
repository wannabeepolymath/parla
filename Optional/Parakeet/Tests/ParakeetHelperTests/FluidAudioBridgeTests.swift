import Foundation
import Testing
@testable import ParakeetHelper

private actor SessionProbe: LocalASRSession {
    var samples: [[Float]] = []
    var filters: [String?] = []
    var cleaned = 0
    var configurations: [LocalModelConfiguration] = []
    func opened(_ value: LocalModelConfiguration) { configurations.append(value) }
    func transcribe(_ samples: [Float], filter: String?) async throws -> String {
        self.samples.append(samples); filters.append(filter)
        return "local text"
    }
    func cleanup() { cleaned += 1 }
}

struct FluidAudioBridgeTests {
    @Test func localBatchAndLoadOnlyReachDriverWithSessionBottom() async throws {
        let probe = SessionProbe()
        let driver = FluidAudioDriver(open: { configuration in
            await probe.opened(configuration)
            return probe
        })
        let directory = URL(fileURLWithPath: "/owned/leased-revision")
        let text = try await driver.run(directory: directory, samples: [0, -0.5, 1], filter: "pl")
        #expect(text == "local text")
        let prepared = try await driver.run(directory: directory, samples: nil, filter: nil)
        #expect(prepared.isEmpty)
        #expect(await probe.configurations == [LocalModelConfiguration(directory: directory), LocalModelConfiguration(directory: directory)])
        #expect(await probe.samples == [[0, -0.5, 1]])
        #expect(await probe.filters == ["pl"])
        #expect(await probe.cleaned == 2)
    }
}
