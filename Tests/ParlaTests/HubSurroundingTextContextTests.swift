import XCTest
@testable import ParlaCore
@testable import Parla

final class HubSurroundingTextContextTests: XCTestCase {
    @MainActor private func hub(_ d: B26AppDocument, recordings: RecordingStore) -> HubModel {
        let imports = AudioImportOwner(); imports.security = { XCTFail("No native security"); return true }
        let templates = GuidedTemplateOwner(); templates.security = { XCTFail("No native security"); return true }
        templates.permission = { XCTFail("No permissions"); return false }
        let h = HubModel(store: d.store, history: d.history, clipboard: { _ in XCTFail("No clipboard") }, recordings: recordings,
            shortcutLabels: ShortcutLabels(center: NotificationCenter(), snapshot: { ShortcutDisplayFormatter { _ in nil } }),
            retryHTTP: B26AppCategory { _ in XCTFail("No HTTP"); throw SurroundingTextFailure.refused },
            diagnostics: DiagnosticStore(now: { 0 }, appVersion: { nil }, osVersion: { .init(majorVersion: 14, minorVersion: 0, patchVersion: 0) }),
            microphoneTest: MicrophoneTestController(allowed: { XCTFail("No mic"); return false }, permission: { XCTFail("No permission"); return false }, schedule: { _, _ in XCTFail("No timer"); return {} }),
            experimentalRetryOwner: ExperimentalHistoryRetryOwner(), audioImport: imports, templates: templates)
        h.loading = true; h.settings = d.store.load(); h.settingsBase = h.settings; h.loading = false
        return h
    }
    @MainActor func testA32ReviewHasExactDisclosureNoReadsAndNeverFlushesOwedSave() throws {
        let d = try B26AppDocument(), rig = try B26AppRig(d), h = hub(d, recordings: rig.recordings)
        var saved = 0; h.onSaved = { saved += 1 }
        h.words = [.init(text: "owed")]
        XCTAssertTrue(h.hasPendingSettingsSave); let base = h.settingsBase
        h.reviewSurrounding(profileID: d.id); XCTAssertNil(h.surroundingReview); XCTAssertEqual(saved, 0); XCTAssertTrue(h.hasPendingSettingsSave)
        h.flushPendingSave(); XCTAssertEqual(saved, 1); XCTAssertNil(h.saveError)
        h.reviewSurrounding(profileID: d.id)
        let review = try XCTUnwrap(h.surroundingReview), disclosure = h.surroundingDisclosure(review.policy)
        for text in ["existing text you did not dictate", "exact-model", "https://context.test/v1", "precedence:", "environment", "Keychain", "raw dictation", "last-result", "alias-to-dated", "billing"] { XCTAssertTrue(disclosure.contains(text)) }
        XCTAssertEqual(d.backend.reads, 0); XCTAssertEqual(d.backend.statuses, 0)
        h.confirmSurrounding(); XCTAssertNotNil(h.surroundingPolicy?.revision); XCTAssertEqual(h.settingsBase.historyEnabled, base.historyEnabled)
        XCTAssertEqual(d.backend.reads, 0)
    }
    @MainActor func testA07A32LocalEditorAwayBackAndFailedDisableRevokeImmediately() throws {
        let d = try B26AppDocument(), rig = try B26AppRig(d); let s = try d.enable(), h = hub(d, recordings: rig.recordings), id = UUID()
        let grant = try XCTUnwrap(d.store.capturePhysicalSurroundingTextGrant(settings: s, destination: .init(bundleID: "test.editor"))).bound(to: id)
        let original = s.profiles[0]; var away = original; away.name = "away"
        h.surroundingProfileDraftChanged(from: original, to: away); h.surroundingProfileDraftChanged(from: away, to: original)
        XCTAssertThrowsError(try d.store.withSurroundingTextGrant(grant, operationID: id) {})
        h.reviewSurrounding(profileID: d.id); h.confirmSurrounding()
        let fresh = try XCTUnwrap(d.store.capturePhysicalSurroundingTextGrant(settings: d.store.load(), destination: .init(bundleID: "test.editor"))).bound(to: id)
        h.words = [.init(text: "owed")]; d.failWrite = true; h.disableSurrounding(profileID: d.id)
        XCTAssertTrue(h.hasPendingSettingsSave); XCTAssertThrowsError(try d.store.withSurroundingTextGrant(fresh, operationID: id) {})
        d.failWrite = false; h.disableSurrounding(profileID: d.id); XCTAssertTrue(h.hasPendingSettingsSave)
        h.flushPendingSave(); XCTAssertNil(h.saveError); XCTAssertEqual(d.store.load().dictionary, ["owed"])
        XCTAssertNil(h.surroundingPolicy); XCTAssertEqual(d.backend.reads, 0)
    }
    @MainActor func testA32ExternalCASAndFailedSaveCannotConfirmStaleReview() throws {
        let d = try B26AppDocument(), rig = try B26AppRig(d), h = hub(d, recordings: rig.recordings)
        h.reviewSurrounding(profileID: d.id); XCTAssertNotNil(h.surroundingReview)
        try d.patch { $0["unknown"] = ["new": true] }
        h.confirmSurrounding(); XCTAssertNil(h.surroundingPolicy)
        h.reviewSurrounding(profileID: d.id); h.saveError = "synthetic write refusal"; h.confirmSurrounding()
        XCTAssertNil(h.surroundingReview); XCTAssertNil(h.surroundingPolicy); XCTAssertEqual(d.backend.reads, 0)
    }
}
