import XCTest
@testable import ParlaCore
@testable import Parla

final class HubCleanupFailoverTests:XCTestCase {
    @MainActor private func hub(_ d:B21AppDocument) -> HubModel {
        let h=HubModel(store:d.store,history:d.history,clipboard:{_ in XCTFail("No clipboard")},
            recordings:RecordingStore(directory:URL(fileURLWithPath:"/synthetic-b21-app/audio"),keepAll:false,writer:{_,_ in XCTFail("No audio writes")},remover:{_ in XCTFail("No audio removal")}),
            shortcutLabels:ShortcutLabels(center:NotificationCenter(),snapshot:{ShortcutDisplayFormatter{_ in nil}}),diagnostics:DiagnosticStore(now:{0},appVersion:{nil},osVersion:{.init(majorVersion:14,minorVersion:0,patchVersion:0)}),
            microphoneTest:MicrophoneTestController(allowed:{XCTFail("No microphone");return false},permission:{XCTFail("No permission");return false},schedule:{_,_ in XCTFail("No microphone timer");return {}}))
        h.loading=true;h.settings=d.store.load();h.settingsBase=h.settings;h.failoverBackups=h.settings.cleanupFailover?.backups ?? [];h.loading=false
        return h
    }
    @MainActor func testB21DedicatedReviewRefusesPendingWithoutFlushDisablePreservesOwedSaveAndBase() throws {
        let d=try B21AppDocument();_=try d.enable();let h=hub(d);var callbacks=0;h.onSaved={callbacks += 1}
        h.words=[.init(text:"word")];XCTAssertTrue(h.hasPendingSettingsSave)
        let oldBase=h.settingsBase;h.reviewFailover();XCTAssertNil(h.failoverReview);XCTAssertEqual(callbacks,0);XCTAssertTrue(h.hasPendingSettingsSave)
        h.disableFailover();XCTAssertNil(h.settings.cleanupFailover?.review);XCTAssertTrue(h.hasPendingSettingsSave)
        XCTAssertEqual(h.settingsBase.historyEnabled,oldBase.historyEnabled);h.flushPendingSave()
        XCTAssertNil(h.saveError);XCTAssertEqual(callbacks,1);XCTAssertEqual(d.store.load().dictionary,["word"])
        h.reviewFailover();XCTAssertNotNil(h.failoverReview);h.confirmFailover();XCTAssertNotNil(d.store.load().cleanupFailover?.review)
    }
    @MainActor func testB21DraftAwayBackFailedDisableAndScopedKeyActionsNeverEnable() throws {
        let d=try B21AppDocument(),s=try d.enable(),h=hub(d),id=UUID()
        let g=try XCTUnwrap(d.store.captureCleanupFailoverGrant(settings:s,origin:.physicalOrdinary)).bound(to:id)
        h.failoverBackups[0].model="other";h.failoverBackups[0].model="backup"
        XCTAssertThrowsError(try d.store.withCleanupFailoverGrant(g,operationID:id,{}))
        d.failWrite=true;h.disableFailover();XCTAssertTrue(d.store.cleanupFailoverIsPaused);d.failWrite=false
        h.disableFailover();h.failoverBackups[0].source = .scopedKeychain
        h.words=[.init(text:"owed")];h.setFailoverKeyDraft(0,"new-key");h.changeFailoverKey(0)
        XCTAssertEqual(d.backend.adds,1);XCTAssertTrue(h.hasPendingSettingsSave);XCTAssertNil(d.store.load().cleanupFailover?.review)
        h.changeFailoverKey(0,remove:true);XCTAssertEqual(d.backend.deletes,1);h.flushPendingSave();XCTAssertNil(h.saveError)
    }
}


extension HubCleanupFailoverTests {
    @MainActor func testB21BackupKeyDraftIsBoundToCanonicalScopeAcrossRowReorder() throws {
        let d=try B21AppDocument();_=try d.enable();let h=hub(d)
        h.failoverBackups=[.init(baseURL:"https://one.test/v1",model:"one",source:.scopedKeychain),.init(baseURL:"https://two.test/v1",model:"two",source:.scopedKeychain)]
        h.setFailoverKeyDraft(0,"only-one");XCTAssertEqual(h.failoverKeyDraft(1),"")
        h.moveFailoverBackup(0,by:1);XCTAssertEqual(h.failoverKeyDraft(0),"");XCTAssertEqual(h.failoverKeyDraft(1),"only-one")
        h.changeFailoverKey(0);XCTAssertEqual(d.backend.adds,0)
        h.changeFailoverKey(1);XCTAssertEqual(d.backend.values[try .compatible("https://one.test/v1")],"only-one")
        XCTAssertNil(d.backend.values[try .compatible("https://two.test/v1")])
    }
}


extension HubCleanupFailoverTests {
    @MainActor func testB21UXEligibilityReviewMatchesAllGlobalModes() throws {
        let modes = [Settings().outputMode, .raw, .selectedPreset]
        for mode in modes {
            for enabled in [false, true] {
                let d = try B21AppDocument()
                var saved = try d.enable(); saved.outputMode = mode; saved.cleanupEnabled = enabled
                if mode == .selectedPreset {
                    let preset = TransformPreset(name: "Rewrite", instruction: "Polish")
                    saved.transformPresets = [preset]; saved.selectedPresetID = preset.id
                }
                d.bytes = try JSONEncoder().encode(saved)
                let h = hub(d), original = d.bytes
                let eligible = mode == .cleanup && enabled
                h.reviewFailover()
                if eligible { XCTAssertNotNil(h.failoverReview) }
                else {
                    XCTAssertNil(h.failoverReview)
                    XCTAssertTrue(h.failoverMessage?.contains("Cleaned up") == true)
                    XCTAssertTrue(h.failoverState.contains("Cleaned up"))
                }
                h.confirmFailover()
                let actual = try d.store.savedRetrySnapshot()
                XCTAssertEqual(actual.outputMode, mode); XCTAssertEqual(actual.cleanupEnabled, enabled)
                if eligible {
                    XCTAssertTrue(h.failoverState.hasPrefix("Enabled"))
                    XCTAssertNotNil(d.store.captureCleanupFailoverGrant(settings: actual, origin: .physicalOrdinary))
                } else {
                    XCTAssertEqual(d.bytes, original)
                    XCTAssertFalse(h.failoverMessage?.hasPrefix("Enabled") == true)
                    XCTAssertNil(d.store.captureCleanupFailoverGrant(settings: actual, origin: .physicalOrdinary))
                }
                XCTAssertEqual(d.backend.reads, 0); XCTAssertEqual(d.backend.statuses, 0)
            }
        }
    }

    @MainActor func testB21UXRevokingDraftClearsEnabledFeedbackAndKeepsOwedSave() throws {
        let d = try B21AppDocument(); _ = try d.enable(); let h = hub(d)
        h.reviewFailover(); h.confirmFailover()
        let saved = try d.store.savedRetrySnapshot(), id = UUID()
        let grant = try XCTUnwrap(d.store.captureCleanupFailoverGrant(settings: saved, origin: .physicalOrdinary)).bound(to: id)
        XCTAssertTrue(h.failoverMessage?.hasPrefix("Enabled") == true)
        var callbacks = 0; h.onSaved = { callbacks += 1 }
        h.words = [.init(text: "owed-word")]
        h.settings.outputMode = .raw
        XCTAssertNil(h.failoverMessage)
        XCTAssertTrue(h.failoverState.contains("Cleaned up"))
        h.settings.outputMode = .cleanup
        XCTAssertTrue(h.hasPendingSettingsSave)
        h.reviewFailover(); h.confirmFailover()
        XCTAssertNil(h.failoverReview); XCTAssertEqual(callbacks, 0)
        XCTAssertTrue(h.hasPendingSettingsSave)
        h.flushPendingSave()
        XCTAssertNil(h.saveError); XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(try d.store.savedRetrySnapshot().dictionary, ["owed-word"])
        XCTAssertTrue(h.failoverState.hasPrefix("Paused"))
        XCTAssertThrowsError(try d.store.withCleanupFailoverGrant(grant, operationID: id, {}))
        h.reviewFailover(); h.confirmFailover()
        XCTAssertTrue(h.failoverState.hasPrefix("Enabled"))
        XCTAssertThrowsError(try d.store.withCleanupFailoverGrant(grant, operationID: id, {}))
        h.settings.cleanupEnabled = false
        XCTAssertNil(h.failoverMessage)
        h.flushPendingSave(); h.reviewFailover()
        XCTAssertNil(h.failoverReview)
        XCTAssertTrue(h.failoverMessage?.contains("Cleaned up") == true)
    }

    @MainActor func testB21UXConfirmRechecksCurrentHubEligibility() throws {
        let d = try B21AppDocument(); _ = try d.enable(); let h = hub(d)
        h.reviewFailover(); XCTAssertNotNil(h.failoverReview)
        let original = d.bytes
        // A loaded projection can change without owing a normal draft save.
        h.loading = true; h.settings.outputMode = .raw; h.loading = false
        XCTAssertFalse(h.hasPendingSettingsSave)
        h.confirmFailover()
        XCTAssertEqual(d.bytes, original)
        XCTAssertNil(h.failoverReview)
        XCTAssertTrue(h.failoverMessage?.contains("Cleaned up") == true)
        XCTAssertEqual(d.backend.reads, 0); XCTAssertEqual(d.backend.statuses, 0)
    }
}
