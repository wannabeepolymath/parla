import Darwin
import Foundation
import XCTest
@testable import ParlaCore

/// Reviewer lock-only probe, extended to every checkpoint of confirmed recovery.
final class B43MeetingRecoveryTests: XCTestCase {
    private func unavailable() throws -> (MeetingVirtualRig,MeetingSessionStore) {
        let rig = MeetingVirtualRig()
        _ = try rig.admit(); _ = try rig.seal(rig.input(0,frames:8000)); try rig.stop()
        _ = try rig.result(meetingID(1000)); try rig.store.detach()
        let manifest = try XCTUnwrap(rig.bottom.rootNode?.children["manifest.json"])
        manifest.body = .metadata(Data("invalid".utf8)); manifest.s.st_size = 7
        let store = reopen(rig.bottom)
        XCTAssertThrowsError(try store.bootstrap())
        return (rig,store)
    }
    private func reopen(_ bottom: MeetingVirtualBottom) -> MeetingSessionStore {
        .init(root:bottom.rootURL,profile:.init(),bottom:bottom,wallClock:{1_000_000_000_000})
    }
    private func admit(_ store: MeetingSessionStore, rig: MeetingVirtualRig) throws {
        XCTAssertEqual(store.projection,.idle)
        _ = try store.admit(owner:meetingID(1),session:rig.session,selections:rig.selections,segments:rig.segments,authorized:{true})
        XCTAssertEqual(store.projection.state,.active)
        _ = try store.terminal(reason:.normalStop,unknownMask:0,generation:1,holdEpoch:1,flags:0x7f,authorized:{true})
        try store.detach()
    }
    /// A process restart retains filesystem identities/bytes, with no descriptors,
    /// flocks or process-local registry. Never resets a poisoned live lease.
    private func relaunched(_ bottom: MeetingVirtualBottom) -> MeetingVirtualBottom {
        func copy(_ node: MeetingVirtualBottom.Node) -> MeetingVirtualBottom.Node {
            let result = MeetingVirtualBottom.Node(name:node.name,inode:UInt64(node.s.st_ino),directory:node.s.st_mode & S_IFMT == S_IFDIR)
            result.s = node.s; result.body = node.body; result.privateRoot = node.privateRoot
            result.children = node.children.mapValues(copy); return result
        }
        let fresh = MeetingVirtualBottom()
        fresh.top.s = bottom.top.s; fresh.top.children = bottom.top.children.mapValues(copy)
        var root: MeetingVirtualBottom.Node? = fresh.top
        for part in fresh.rootURL.path.split(separator:"/") { root = root?.children[String(part)] }
        fresh.rootNode = root
        return fresh
    }
    func testRecoveryCanResumeAfterItsLastOwnerMarkerWasRemoved() throws {
        let (trace,complete) = try unavailable()
        trace.bottom.reset(); try complete.deleteAllUnavailableMeetingData(authorized:{true})
        let cut = try XCTUnwrap(trace.bottom.events.firstIndex { $0.0 == "unlink" && $0.1 == "lock" })
        for relaunch in [false,true] {
            let (crash,store) = try unavailable()
            crash.bottom.reset(cut:cut)
            XCTAssertThrowsError(try store.deleteAllUnavailableMeetingData(authorized:{true}))
            XCTAssertEqual(crash.bottom.names,["lock"]); XCTAssertTrue(crash.bottom.descriptors.isEmpty)
            crash.bottom.reset()
            let recovered: MeetingSessionStore
            if relaunch {
                recovered = reopen(crash.bottom)
                XCTAssertEqual(try recovered.bootstrap(),.idle)
            } else {
                XCTAssertTrue(store.canDeleteUnavailableMeetingData)
                try store.deleteAllUnavailableMeetingData(authorized:{true}); recovered = store
            }
            XCTAssertTrue(crash.bottom.names.isEmpty,"The single meeting slot remains unusable")
            try admit(recovered,rig:crash)
        }
    }
    func testEveryRecoveryCheckpointRestoresUsableSlotAfterRelaunch() throws {
        let (trace,complete) = try unavailable()
        trace.bottom.reset(); try complete.deleteAllUnavailableMeetingData(authorized:{true})
        let events = trace.bottom.events
        XCTAssertTrue(events.contains { $0.0 == "rmdir-parent-sync" })
        var lockOnlyCuts = 0, emptyRootCuts = 0
        for cut in events.indices {
            let (crash,store) = try unavailable()
            crash.bottom.reset(cut:cut)
            XCTAssertThrowsError(try store.deleteAllUnavailableMeetingData(authorized:{true}),"cut \(cut): \(events[cut])")
            XCTAssertTrue(crash.bottom.descriptors.isEmpty)
            if crash.bottom.names == ["lock"] { lockOnlyCuts += 1 }
            let disk = relaunched(crash.bottom)
            if disk.rootNode != nil,disk.names.isEmpty { emptyRootCuts += 1 }
            let recovered = reopen(disk)
            do { let projection = try recovered.bootstrap(); XCTAssertEqual(projection,.idle) }
            catch {
                XCTAssertTrue(recovered.canDeleteUnavailableMeetingData,"cut \(cut): \(events[cut])")
                try recovered.deleteAllUnavailableMeetingData(authorized:{true})
            }
            XCTAssertTrue(disk.names.isEmpty,"cut \(cut): \(events[cut])")
            try admit(recovered,rig:crash)
            XCTAssertTrue(disk.descriptors.isEmpty)
        }
        XCTAssertGreaterThan(lockOnlyCuts,0); XCTAssertGreaterThan(emptyRootCuts,0)
        print("B43 recovery checkpoints: \(events.count), lock-only: \(lockOnlyCuts), empty-root: \(emptyRootCuts)")
    }
    func testRemnantRecoveryRequiresPrivateIdentityAndNoPayload() throws {
        for variant in ["lock","empty","foreign","source","foreign-no-lock","source-no-lock","contended","lock-symlink","lock-owner","lock-mode","lock-links","lock-bytes","root-symlink","root-owner","root-mode"] {
            let (rig,store) = try unavailable()
            let root = try XCTUnwrap(rig.bottom.rootNode)
            root.children = root.children.filter { $0.key == "lock" }
            let lock = try XCTUnwrap(root.children["lock"])
            switch variant {
            case "empty": root.children.removeAll()
            case "foreign": try rig.bottom.add("foreign.txt")
            case "source": try rig.bottom.add(MeetingSession.uuid(meetingID(1000))+".source.wav")
            case "foreign-no-lock": root.children.removeAll(); try rig.bottom.add("foreign.txt")
            case "source-no-lock": root.children.removeAll(); try rig.bottom.add(MeetingSession.uuid(meetingID(1000))+".source.wav")
            case "contended": lock.locked = true
            case "lock-symlink": lock.s.st_mode = 0o120600
            case "lock-owner": lock.s.st_uid = 502
            case "lock-mode": lock.s.st_mode = mode_t(S_IFREG | 0o644)
            case "lock-links": lock.s.st_nlink = 2
            case "lock-bytes": lock.body = .metadata(Data([1])); lock.s.st_size = 1
            case "root-symlink": root.s.st_mode = 0o120700
            case "root-owner": root.s.st_uid = 502
            case "root-mode": root.s.st_mode = mode_t(S_IFDIR | 0o755)
            default: break
            }
            let names = rig.bottom.names, nodes = root.children.mapValues { ObjectIdentifier($0) }
            XCTAssertThrowsError(try store.deleteAllUnavailableMeetingData(authorized:{false}))
            XCTAssertEqual(rig.bottom.names,names)
            if variant == "lock" || variant == "empty" {
                try store.deleteAllUnavailableMeetingData(authorized:{true})
                try admit(store,rig:rig)
            } else {
                XCTAssertThrowsError(try store.deleteAllUnavailableMeetingData(authorized:{true}),variant)
                XCTAssertEqual(root.children.mapValues { ObjectIdentifier($0) },nodes,variant)
                let cold = reopen(rig.bottom)
                XCTAssertThrowsError(try cold.bootstrap(),variant)
                XCTAssertEqual(root.children.mapValues { ObjectIdentifier($0) },nodes,variant)
            }
            XCTAssertTrue(rig.bottom.descriptors.isEmpty)
        }
    }
}
