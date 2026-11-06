import XCTest
@testable import Parla
@testable import ParlaCore

final class SurroundingTextContextRegressionTests: XCTestCase {
    @MainActor func testCloudEchoRejectedAndShortOrDictatedOverlapAccepted() async throws {
        let secret = "The private passphrase is lavender ocean and must remain confidential."
        let raw = "Please review the complete proposal before the meeting tomorrow"
        // Rejection controls share this method with acceptance controls so removing
        // the guard fails this regression even though the controls still pass.
        let cases: [(String, String, String, Bool)] = [
            (secret, raw, secret, true),
            (secret, raw, raw + ". " + secret, true),
            (secret, raw, "Please mention lavender ocean tomorrow.", false),
            (secret, "The private passphrase is lavender ocean", "The private passphrase is lavender ocean.", false),
            ("Über, STRAẞE naïve résumé remains private.", raw, "ÜBER straße NAÏVE RÉSUMÉ!", true)
        ]
        for provider in ["anthropic", "openai-compatible"] {
            for (context, dictated, output, rejected) in cases {
                let d = try B26AppDocument(provider: provider), rig = try B26AppRig(d), s = try rig.start()
                let ax = SyntheticSurroundingAX(), http = B26AppHTTP()
                ax.units = Array(context.utf16); rig.raw = dictated
                http.onResume = { [unowned http] in http.text = http.resumed == 1 ? output : "Please review the proposal." }
                await rig.work(s, field: B26AppField(), http: http, port: ax.port).value
                XCTAssertEqual(rig.posted, [rejected ? "Please review the proposal." : output])
                XCTAssertEqual(http.requests.count, rejected ? 2 : 1)
                XCTAssertEqual(rig.categories, 0)
                if rejected, http.requests.count == 2 {
                    let first = try XCTUnwrap(http.requests[0].httpBody), retry = try XCTUnwrap(http.requests[1].httpBody)
                    XCTAssertTrue(String(decoding: first, as: UTF8.self).contains("preceding_text"))
                    XCTAssertFalse(String(decoding: retry, as: UTF8.self).contains("preceding_text"))
                    XCTAssertEqual(http.requests[0].url, http.requests[1].url)
                    XCTAssertEqual(http.requests[0].allHTTPHeaderFields, http.requests[1].allHTTPHeaderFields)
                    let firstJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
                    let retryJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: retry) as? [String: Any])
                    XCTAssertEqual(firstJSON["model"] as? String, retryJSON["model"] as? String)
                }
                XCTAssertNil(d.history.entries.first?.cleaned)
                XCTAssertTrue(rig.learned.isEmpty)
                XCTAssertFalse(String(decoding: d.historyBytes, as: UTF8.self).contains(context))
            }
        }
        for retryResult in ["", secret, "transport-error"] {
            let d = try B26AppDocument(), rig = try B26AppRig(d), s = try rig.start()
            let ax = SyntheticSurroundingAX(), http = B26AppHTTP()
            ax.units = Array(secret.utf16); rig.raw = raw
            http.onResume = { [unowned http] in
                http.text = http.resumed == 1 ? secret : retryResult
                if http.resumed == 2 && retryResult == "transport-error" { http.status = 503 }
            }
            await rig.work(s, field: B26AppField(), http: http, port: ax.port).value
            XCTAssertEqual(rig.posted, [raw]); XCTAssertEqual(http.requests.count, 2)
            XCTAssertEqual(rig.categories, 0); XCTAssertNil(d.history.entries.first?.cleaned)
            XCTAssertFalse(String(decoding: d.historyBytes, as: UTF8.self).contains(secret))
        }
    }
    @MainActor func testLocalEchoRejectedAndContextFreeRetryOrRawFallbackUsed() async throws {
        for retryFails in [false, true] {
            let d = try B26AppDocument(provider: "apple-intelligence")
            try d.patch { root in
                var cleanup = root["cleanup"] as! [String: Any]
                cleanup["localSourceLocale"] = "en"
                root["cleanup"] = cleanup; root["profiles"] = []
            }
            let rig = try B26AppRig(d), s = try rig.start(reviewed: false)
            let ax = SyntheticSurroundingAX(), http = B26AppHTTP(), state = B26EchoLocalState()
            let secret = "The private passphrase is lavender ocean and must remain confidential."
            ax.units = Array(secret.utf16)
            rig.raw = "Please review the complete proposal before the meeting tomorrow"
            let runtime = LocalCleanupRuntime(availability: { _ in nil }, language: { _ in ["en": 0.99] }, generate: { prompt, attempted in
                try attempted(); state.prompts.append(prompt)
                if state.prompts.count == 1 { return secret }
                if retryFails { throw SurroundingTextFailure.refused }
                return "Please review the complete proposal before the meeting tomorrow."
            }, now: { 100 }, sleep: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }, appLocale: { "en" })
            await rig.work(s, field: B26AppField(), http: http, port: ax.port, localRuntime: runtime).value
            XCTAssertEqual(rig.posted, [retryFails ? rig.raw : rig.raw + "."])
            XCTAssertEqual(state.prompts.count, 2)
            XCTAssertTrue(state.prompts.first?.user.contains("preceding_text") == true)
            XCTAssertFalse(state.prompts.last?.user.contains(secret) == true)
            XCTAssertEqual(http.constructed, 0); XCTAssertEqual(rig.categories, 0); XCTAssertEqual(d.backend.reads, 0)
            XCTAssertNil(d.history.entries.first?.cleaned)
            XCTAssertFalse(String(decoding: d.historyBytes, as: UTF8.self).contains(secret))
        }
    }
    @MainActor func testScreenSharingAndExplicitRemoteClientsRefuseNativeContextRead() async throws {
        for bundle in ["com.apple.ScreenSharing", "com.apple.RemoteDesktop", "com.microsoft.rdc.macos", "com.microsoft.rdc.osx.beta", "com.teamviewer.TeamViewer", "com.philandro.anydesk", "com.p5sys.jump.mac.viewer", "tv.parsec.www", "com.realvnc.vncviewer", "com.splashtop.business.client"] {
            let ax = SyntheticSurroundingAX(); ax.bundle = bundle
            let scope = try XCTUnwrap(ax.port.open(UUID(), ax.bundle))
            let observation = try await scope.proof(admit: { 1 })
            // Exercise the original probe's read path if production admits it.
            if let field = observation {
                let read = try scope.issue(field, range: field.request, admit: { 1 })
                _ = try await read.value()
            }
            await scope.finishAndWaitForExit()
            XCTAssertNil(observation, bundle)
            XCTAssertTrue(ax.requests.isEmpty, bundle)
            XCTAssertTrue(ax.timeouts.isEmpty, bundle)
        }
    }
}
private final class B26EchoLocalState: @unchecked Sendable { var prompts: [LocalCleanupPrompt] = [] }
