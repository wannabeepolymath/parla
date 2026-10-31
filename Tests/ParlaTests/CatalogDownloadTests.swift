import AppKit
import Darwin
import XCTest
@testable import ParlaCore
@testable import Parla

private actor DownloadScript: CatalogDownloadTransport {
    struct Reply {
        var status = 206
        var headers: [String: String] = [:]
        var body = Data()
        var fail = false
        var hold = false
    }
    var replies: [Reply]
    var requests: [URLRequest] = []
    var gate: CheckedContinuation<Void, Never>?
    var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func fetch(_ request: URLRequest, to file: URL, maximum: Int64, chunkMaximum: Int64) async throws -> HTTPURLResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw CatalogDownloadFailure() }
        let reply = replies.removeFirst()
        if reply.hold {
            await withCheckedContinuation { continuation in
                gate = continuation
                notify()
            }
        } else { notify() }
        // Deliberately ignores task cancellation: the owner must await exit and
        // refuse publication even if an old transport supplies a late success.
        if reply.fail { throw URLError(.networkConnectionLost) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.write(contentsOf: reply.body); try handle.synchronize()
        return HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
    }
    private func notify() {
        let ready = waiters.filter { requests.count >= $0.0 }
        waiters.removeAll { requests.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func release() { let continuation = gate; gate = nil; continuation?.resume() }
}

@MainActor
private final class DownloadRig {
    let root: URL, bytes: Data
    let model: ModelCatalog.Model
    let cache: VerifiedCache, store: SettingsStore, hub: HubModel
    var setups = 0
    var owners: [CatalogDownloadOwner] = []
    var staging: URL { root.appendingPathComponent("downloads") }
    var installed: URL { root.appendingPathComponent("installed.bin") }
    init(atomicWrite: ((Data, URL) throws -> Void)? = nil) throws {
        bytes = Data("ggmltest1234".utf8)
        root = try DownloadTestPaths.parent().appendingPathComponent("parla-wave4a-\(UUID().uuidString)")
        guard mkdir(root.path, 0o700) == 0 else { throw CatalogDownloadFailure() }
        try recordWave4BFixture(root, "created")
        let source = root.appendingPathComponent("fixture")
        try bytes.write(to: source)
        model = ModelCatalog.Model(id: "base.en", displayName: "Fixture", bytes: Int64(bytes.count), sha256: try ModelCatalog.sha256(ofFileAt: source))
        cache = VerifiedCache(url: root.appendingPathComponent("verified.json"))
        if let atomicWrite { store = SettingsStore(url: root.appendingPathComponent("settings.json"), credentials: testCredentialStore(), atomicWrite: atomicWrite) }
        else { store = SettingsStore(url: root.appendingPathComponent("settings.json"), credentials: testCredentialStore()) }
        hub = HubModel(store: store, history: HistoryStore(url: root.appendingPathComponent("history.json")), recordings: RecordingStore(directory: root.appendingPathComponent("recordings")))
    }
    // Only the process acceptance test supplies this already-owned location.
    // Reopening checks the pinned fixture; it never fabricates a checkpoint.
    init(processRoot: URL, create: Bool) throws {
        bytes = Data("ggmltest123".utf8)
        root = processRoot
        let source = root.appendingPathComponent("fixture")
        if create {
            guard mkdir(root.path, 0o700) == 0 else { throw CatalogDownloadFailure() }
            try recordWave4BFixture(root, "created")
            try bytes.write(to: source)
        }
        try DownloadTestPaths.validateLeaf(root, parent: root.deletingLastPathComponent())
        guard try Data(contentsOf: source) == bytes else { throw CatalogDownloadFailure() }
        model = ModelCatalog.Model(id: "base.en", displayName: "Fixture", bytes: Int64(bytes.count), sha256: try ModelCatalog.sha256(ofFileAt: source))
        cache = VerifiedCache(url: root.appendingPathComponent("verified.json"))
        store = SettingsStore(url: root.appendingPathComponent("settings.json"), credentials: testCredentialStore())
        hub = HubModel(store: store, history: HistoryStore(url: root.appendingPathComponent("history.json")), recordings: RecordingStore(directory: root.appendingPathComponent("recordings")))
    }
    func owner(_ script: CatalogDownloadTransport, model: ModelCatalog.Model? = nil,
               installer: ((URL, ModelCatalog.Model, URL, VerifiedCache) throws -> Void)? = nil) -> CatalogDownloadOwner {
        let owner = CatalogDownloadOwner(root: staging, catalog: [model ?? self.model], transport: script, chunkBytes: 4,
            destination: { [installed] _ in installed }, cache: cache,
            installer: installer ?? { try ModelCatalog.install(staged: $0, as: $1, at: $2, cache: $3) })
        owners.append(owner)
        hub.bindCatalogDownloads(owner, setup: { [weak self] in self?.setups += 1 })
        return owner
    }
    func part(_ start: Int, tag: String? = "\"r1\"", hold: Bool = false) -> DownloadScript.Reply {
        let end = min(start + 4, bytes.count) - 1
        var headers = ["Content-Range": "bytes \(start)-\(end)/\(bytes.count)"]
        if let tag { headers["ETag"] = tag }
        return .init(headers: headers, body: bytes.subdata(in: start..<(end + 1)), hold: hold)
    }
    var full: DownloadScript.Reply { .init(status: 200, body: bytes) }
    func cleanup() async {
        hub.flushPendingSave()
        for owner in owners { owner.pause(); await owner.waitForExit() }
        do {
            try FileManager.default.removeItem(at: root)
            try recordWave4BFixture(root, "removed")
        } catch {
            try? recordWave4BFixture(root, "cleanup-uncertain")
        }
    }
}

@MainActor
final class CatalogDownloadTests: XCTestCase {
    func testFreshFull200UsesRealInstallerCacheAndProductionSelection() async throws {
        let r = try DownloadRig(); let script = DownloadScript([r.full]); let owner = r.owner(script)
        let observed1 = await script.requests
        XCTAssertTrue(observed1.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.staging.path))
        r.hub.onDownloadModel(r.model); await owner.waitForExit()
        XCTAssertEqual(try Data(contentsOf: r.installed), r.bytes)
        XCTAssertTrue(r.cache.isVerified(r.installed)); XCTAssertEqual(r.setups, 1)
        XCTAssertEqual(r.store.load().whisperModelPath, ModelCatalog.path(for: r.model))
        XCTAssertEqual(owner.rows[r.model.id]?.phase, .installed)
        let request = await script.requests.first!
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-3")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        await r.cleanup()
    }
    func testMultiple206AndStrongIfRangeInstallExactBytes() async throws {
        let r = try DownloadRig(); let script = DownloadScript([r.part(0), r.part(4), r.part(8)])
        let owner = r.owner(script); r.hub.onDownloadModel(r.model); await owner.waitForExit()
        XCTAssertEqual(try Data(contentsOf: r.installed), r.bytes)
        let requests = await script.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-Range"), "\"r1\"")
        await r.cleanup()
    }
    func testReconstructedOwnerResumesCommittedBytesPassively() async throws {
        let r = try DownloadRig(); let initial = DownloadScript([r.part(0), .init(fail: true)])
        let first = r.owner(initial); r.hub.onDownloadModel(r.model); await first.waitForExit()
        XCTAssertEqual(try first.storage.inspect(r.model)?.committed, 4)
        XCTAssertFalse(r.cache.isVerified(r.installed)); XCTAssertEqual(r.setups, 0)
        let script = DownloadScript([r.part(4), r.part(8)])
        let second = r.owner(script)
        XCTAssertEqual(second.rows[r.model.id]?.phase, .paused)
        let observed2 = await script.requests
        XCTAssertEqual(observed2.count, 0)
        r.hub.onCatalogDownloadAction(.resume, r.model); await second.waitForExit()
        let observed3 = await script.requests
        XCTAssertEqual(observed3.first?.value(forHTTPHeaderField: "Range"), "bytes=4-7")
        XCTAssertEqual(try Data(contentsOf: r.installed), r.bytes); XCTAssertEqual(r.setups, 1)
        await r.cleanup()
    }
    /// macOS XCTest only: re-execute the current runner/bundle, targeting this
    /// method alone. These are clean process exits, not power-loss simulation.
    func testProcessRestartResumesCommittedDownload() async throws {
        let env = ProcessInfo.processInfo.environment
        let parent = try DownloadTestPaths.parent(environment: env)
        if let (role, nonce, root) = try DownloadProcessEvidence.reentry(environment: env, parent: parent) {
            let r = try DownloadRig(processRoot: root.appendingPathComponent("fixture-root"), create: role == "checkpoint")
            let old = Data("previous-installed-model".utf8)
            if role == "checkpoint" { try old.write(to: r.installed) }
            let script = DownloadScript(role == "checkpoint" ? [r.part(0), .init(fail: true)] : [r.part(4), r.part(8)])
            let owner = r.owner(script)
            let before = try owner.storage.inspect(r.model)
            let stage = before.map { r.staging.appendingPathComponent($0.staging) }
            let stageIdentity = try stage.map(DownloadProcessEvidence.identity)
            try await Task.sleep(nanoseconds: 50_000_000)
            let passive = await script.requests
            XCTAssertTrue(passive.isEmpty)
            XCTAssertFalse(owner.isActive)
            XCTAssertEqual(r.setups, 0)
            XCTAssertNil(r.store.load().whisperModelPath)
            XCTAssertFalse(r.cache.isVerified(r.installed))
            XCTAssertEqual(try Data(contentsOf: r.installed), old)
            if role == "checkpoint" {
                XCTAssertNil(before)
                r.hub.onDownloadModel(r.model)
            } else {
                XCTAssertEqual(before?.committed, 4)
                XCTAssertEqual(before?.validator, .etag("\"r1\""))
                XCTAssertEqual(owner.rows[r.model.id]?.phase, .paused)
                XCTAssertEqual(try Data(contentsOf: XCTUnwrap(stage)), r.bytes.prefix(4))
                r.hub.onCatalogDownloadAction(.resume, r.model)
            }
            await owner.waitForExit()
            r.hub.flushPendingSave()
            let requests = await script.requests
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Range") },
                           role == "checkpoint" ? ["bytes=0-3", "bytes=4-7"] : ["bytes=4-7", "bytes=8-10"])
            XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "If-Range"), role == "resume" ? "\"r1\"" : nil)
            XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "If-Range"), "\"r1\"")
            XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Accept-Encoding") == "identity" })
            let after = try owner.storage.inspect(r.model)
            if role == "checkpoint" {
                XCTAssertEqual(after?.committed, 4)
                XCTAssertEqual(after?.validator, .etag("\"r1\""))
                XCTAssertEqual(owner.rows[r.model.id]?.phase, .failed)
                XCTAssertEqual(try Data(contentsOf: r.staging.appendingPathComponent(XCTUnwrap(after).staging)), r.bytes.prefix(4))
                XCTAssertEqual(try Data(contentsOf: r.installed), old)
                XCTAssertFalse(r.cache.isVerified(r.installed))
                XCTAssertEqual(r.setups, 0)
                XCTAssertNil(r.store.load().whisperModelPath)
            } else {
                XCTAssertNil(after)
                XCTAssertEqual(owner.rows[r.model.id]?.phase, .installed)
                XCTAssertEqual(try Data(contentsOf: r.installed), r.bytes)
                try ModelCatalog.verify(fileAt: r.installed, is: r.model)
                XCTAssertTrue(VerifiedCache(url: r.root.appendingPathComponent("verified.json")).isVerified(r.installed))
                XCTAssertEqual(try DownloadProcessEvidence.identity(r.installed), stageIdentity)
                XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(stage).path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: r.installed.appendingPathExtension("backup").path))
                XCTAssertEqual(r.setups, 1)
                XCTAssertEqual(r.store.load().whisperModelPath, ModelCatalog.path(for: r.model))
            }
            let checkpoint = role == "checkpoint" ? try XCTUnwrap(after) : try XCTUnwrap(before)
            let receipt = DownloadProcessEvidence.Phase(role: role, nonce: nonce, pid: getpid(), parentPID: getppid(),
                environment: .init(values: env, parent: parent),
                root: r.root.path, modelBytes: r.model.bytes, sha256: r.model.sha256, committed: checkpoint.committed,
                stageIdentity: try stageIdentity ?? DownloadProcessEvidence.identity(r.staging.appendingPathComponent(checkpoint.staging)),
                passiveRequests: passive.count, ranges: requests.compactMap { $0.value(forHTTPHeaderField: "Range") },
                ifRanges: requests.map { $0.value(forHTTPHeaderField: "If-Range") },
                installedBytes: try Data(contentsOf: r.installed).count, installedSHA256: try ModelCatalog.sha256(ofFileAt: r.installed),
                cacheVerified: r.cache.isVerified(r.installed), setups: r.setups, selectedPath: r.store.load().whisperModelPath)
            try JSONEncoder().encode(receipt).write(to: root.appendingPathComponent(role + ".json"), options: .atomic)
            return // XCTest must report/pass and actually exit before the next process starts.
        }

        let nonce = UUID().uuidString
        let root = parent.appendingPathComponent("download-process-child-" + nonce)
        guard mkdir(root.path, 0o700) == 0 else { throw CatalogDownloadFailure() }
        try recordWave4BFixture(root, "created")
        let runner = try XCTUnwrap(Bundle.main.executableURL)
        let bundle = Bundle(for: CatalogDownloadTests.self).bundleURL
        guard runner.lastPathComponent == "xctest", bundle.pathExtension == "xctest" else {
            XCTFail("Process acceptance requires the current macOS xctest runner and test bundle; evidence: \(root.path)")
            return
        }
        let arguments = ["-XCTest", "ParlaTests.CatalogDownloadTests/testProcessRestartResumesCommittedDownload", bundle.path]
        let first = try await DownloadProcessEvidence.run(role: "checkpoint", nonce: nonce, root: root, runner: runner, arguments: arguments)
        let second = try await DownloadProcessEvidence.run(role: "resume", nonce: nonce, root: root, runner: runner, arguments: arguments)
        XCTAssertNotEqual(first.pid, second.pid)
        XCTAssertNotEqual(first.pid, getpid()); XCTAssertNotEqual(second.pid, getpid())
        XCTAssertLessThanOrEqual(first.exited, second.started)
        let phases = try ["checkpoint", "resume"].map {
            try JSONDecoder().decode(DownloadProcessEvidence.Phase.self, from: Data(contentsOf: root.appendingPathComponent($0 + ".json")))
        }
        XCTAssertEqual(phases.map(\.pid), [first.pid, second.pid])
        XCTAssertTrue(phases.allSatisfy { $0.parentPID == getpid() && $0.nonce == nonce && $0.committed == 4 && $0.modelBytes == 11 })
        XCTAssertTrue(phases.allSatisfy {
            $0.root == root.appendingPathComponent("fixture-root").path &&
            $0.environment.effectiveParent == parent.path && $0.environment.assignedParent == parent.path
        })
        XCTAssertEqual(phases[0].sha256, phases[1].sha256)
        XCTAssertEqual(phases[0].stageIdentity, phases[1].stageIdentity)
        // Logs/receipts survive fixture cleanup for independent review.
        let fixture = root.appendingPathComponent("fixture-root")
        if testRun?.failureCount == 0 {
            try DownloadTestPaths.validateLeaf(root, parent: parent)
            try DownloadTestPaths.validateLeaf(fixture, parent: root)
            try FileManager.default.removeItem(at: fixture)
            try recordWave4BFixture(fixture, "removed")
        }
        try recordWave4BFixture(root, "retained-process-evidence")
    }
    func testAssignedDownloadFixtureParentAndReentryValidation() throws {
        let parent = try DownloadTestPaths.parent()
        let root = parent.appendingPathComponent("download-parent-validation-" + UUID().uuidString)
        guard mkdir(root.path, 0o700) == 0 else { throw CatalogDownloadFailure() }
        try recordWave4BFixture(root, "created")
        defer {
            do {
                try FileManager.default.removeItem(at: root)
                try recordWave4BFixture(root, "removed")
            } catch { XCTFail("Owned validation fixture cleanup failed") }
        }
        XCTAssertEqual(try DownloadTestPaths.parent(environment: [:]), FileManager.default.temporaryDirectory.resolvingSymlinksInPath())
        let key = DownloadTestPaths.parentKey
        XCTAssertEqual(try DownloadTestPaths.parent(environment: [key: root.path]).path, root.path)
        for path in ["", "relative", root.appendingPathComponent("missing").path] {
            XCTAssertThrowsError(try DownloadTestPaths.parent(environment: [key: path]))
        }
        let file = root.appendingPathComponent("file"), alias = root.appendingPathComponent("alias")
        try Data().write(to: file)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        for path in [file.path, alias.path] {
            XCTAssertThrowsError(try DownloadTestPaths.parent(environment: [key: path]))
        }
        XCTAssertNil(try DownloadProcessEvidence.reentry(environment: [:], parent: root))
        let nonce = UUID().uuidString, leaf = root.appendingPathComponent("download-process-child-" + nonce)
        guard mkdir(leaf.path, 0o700) == 0 else { throw CatalogDownloadFailure() }
        let valid = [DownloadProcessEvidence.roleKey: "checkpoint", DownloadProcessEvidence.nonceKey: nonce,
                     DownloadProcessEvidence.rootKey: leaf.path]
        XCTAssertEqual(try DownloadProcessEvidence.reentry(environment: valid, parent: root)?.2.path, leaf.path)
        for key in valid.keys {
            var partial = valid; partial.removeValue(forKey: key)
            XCTAssertThrowsError(try DownloadProcessEvidence.reentry(environment: partial, parent: root))
        }
        for (key, value) in [(DownloadProcessEvidence.roleKey, "other"), (DownloadProcessEvidence.nonceKey, UUID().uuidString),
                             (DownloadProcessEvidence.rootKey, file.path)] {
            var invalid = valid; invalid[key] = value
            XCTAssertThrowsError(try DownloadProcessEvidence.reentry(environment: invalid, parent: root))
        }
        try FileManager.default.removeItem(at: leaf)
        try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: root)
        XCTAssertThrowsError(try DownloadProcessEvidence.reentry(environment: valid, parent: root))
    }
    func testMissingAndWeakETagCannotAuthorizeAppend() async throws {
        for tag in [nil, "W/\"weak\"", "invalid"] as [String?] {
            let r = try DownloadRig(); let script = DownloadScript([r.part(0, tag: tag), r.full])
            let owner = r.owner(script); r.hub.onDownloadModel(r.model); await owner.waitForExit()
            let requests = await script.requests
            XCTAssertNil(requests[1].value(forHTTPHeaderField: "Range"))
            XCTAssertNil(requests[1].value(forHTTPHeaderField: "If-Range"))
            XCTAssertEqual(try Data(contentsOf: r.installed), r.bytes)
            await r.cleanup()
        }
    }
    func testChangedValidatorRefusesAppendKeepsInstalledModel() async throws {
        for tag in [nil, "W/\"r1\"", "\"changed\""] as [String?] {
            let r = try DownloadRig(); try Data("old".utf8).write(to: r.installed)
            let script = DownloadScript([r.part(0), r.part(4, tag: tag)])
            let owner = r.owner(script); r.hub.onDownloadModel(r.model); await owner.waitForExit()
            XCTAssertEqual(owner.rows[r.model.id]?.phase, .failed)
            XCTAssertEqual(try owner.storage.inspect(r.model)?.committed, 4)
            XCTAssertEqual(try Data(contentsOf: r.installed), Data("old".utf8)); XCTAssertEqual(r.setups, 0)
            await r.cleanup()
        }
    }
    func testStrictLastModifiedUsesDateOnlyWithoutETagAndWithSixtySecondAge() async throws {
        let modified = "Wed, 21 Oct 2015 07:28:00 GMT", date = "Wed, 21 Oct 2015 07:30:00 GMT"
        for valid in [true, false] {
            let r = try DownloadRig()
            var replies = [r.part(0, tag: nil), r.part(4, tag: nil), r.part(8, tag: nil)]
            for i in replies.indices {
                replies[i].headers["Last-Modified"] = modified
                replies[i].headers["Date"] = valid ? date : "Wed, 21 Oct 2015 07:28:30 GMT"
            }
            if !valid { replies[1] = r.full }
            let script = DownloadScript(replies), owner = r.owner(script)
            r.hub.onDownloadModel(r.model); await owner.waitForExit()
            XCTAssertEqual(try Data(contentsOf: r.installed), r.bytes)
        let observed4 = await script.requests
            XCTAssertEqual(observed4[1].value(forHTTPHeaderField: "If-Range"), valid ? modified : nil)
            await r.cleanup()
        }
    }
    func testInvalidDateAndWeakETagWithDateUseFullRestart() async throws {
        for headers in [["Last-Modified": "yesterday", "Date": "Wed, 21 Oct 2015 07:30:00 GMT"],
                        ["Last-Modified": "Wed, 21 Oct 2015 07:28:00 GMT"],
                        ["ETag": "W/\"weak\"", "Last-Modified": "Wed, 21 Oct 2015 07:28:00 GMT", "Date": "Wed, 21 Oct 2015 07:30:00 GMT"]] {
            let r = try DownloadRig(); var first = r.part(0, tag: nil); first.headers.merge(headers) { _, new in new }
            let script = DownloadScript([first, r.full]), owner = r.owner(script)
            r.hub.onDownloadModel(r.model); await owner.waitForExit()
        let observed5 = await script.requests
            XCTAssertNil(observed5[1].value(forHTTPHeaderField: "Range"))
            XCTAssertEqual(try Data(contentsOf: r.installed), r.bytes)
            await r.cleanup()
        }
    }
    func testIgnoredRange200NeverAppendsAndPinsFullSize() async throws {
        let r = try DownloadRig(); let script = DownloadScript([r.part(0), r.full]), owner = r.owner(script)
        r.hub.onDownloadModel(r.model); await owner.waitForExit()
        let observed6 = await script.requests
        XCTAssertEqual(try Data(contentsOf: r.installed), r.bytes); XCTAssertEqual(observed6.count, 2)
        await r.cleanup()
    }
    func test416ResetsOnlyOnceAndCompleteStageNeedsNoNetwork() async throws {
        let r = try DownloadRig()
        let unsatisfied = DownloadScript.Reply(status: 416, headers: ["Content-Range": "bytes */12"])
        let script = DownloadScript([unsatisfied, r.full]), owner = r.owner(script)
        _ = try owner.storage.prepare(r.model, generation: UUID())
        r.hub.onDownloadModel(r.model); await owner.waitForExit()
        XCTAssertEqual(try Data(contentsOf: r.installed), r.bytes)
        let observed7 = await script.requests
        XCTAssertNil(observed7[1].value(forHTTPHeaderField: "Range"))
        await r.cleanup()
        let failedRig = try DownloadRig(); let repeated = DownloadScript([unsatisfied, unsatisfied]), failed = failedRig.owner(repeated)
        failedRig.hub.onDownloadModel(failedRig.model); await failed.waitForExit()
        let observed8 = await repeated.requests
        XCTAssertEqual(failed.rows[failedRig.model.id]?.phase, .failed); XCTAssertEqual(observed8.count, 2)
        await failedRig.cleanup()
    }
    func testHTTPAndChunkMatrixRejectsWithoutCommitOrInstalledDamage() async throws {
        let r = try DownloadRig(); let good = r.part(0)
        var variants: [DownloadScript.Reply] = []
        for range in ["bytes 1-4/12", "bytes 0-2/12", "bytes 0-4/12", "bytes 0-3/13", "bytes */12", "bytes 0-3/12, 4-7/12"] {
            var bad = good; bad.headers["Content-Range"] = range; variants.append(bad)
        }
        for (key, value) in [("Content-Encoding", "gzip"), ("Content-Type", "multipart/byteranges; boundary=x"), ("Content-Length", "999")] {
            var bad = good; bad.headers[key] = value; variants.append(bad)
        }
        variants += [.init(status: 404, body: Data("no".utf8)), .init(status: 503), .init(status: 302),
                     .init(status: 416, headers: ["Content-Range": "bytes */13"]),
                     .init(headers: good.headers, body: Data("ggm".utf8)),
                     .init(headers: good.headers, body: Data("ggmlx".utf8)), .init(fail: true)]
        try Data("old".utf8).write(to: r.installed)
        for reply in variants {
            let script = DownloadScript([reply]), owner = r.owner(script)
            r.hub.onDownloadModel(r.model); await owner.waitForExit()
            XCTAssertEqual(owner.rows[r.model.id]?.phase, .failed, "\(reply)")
            XCTAssertEqual(try owner.storage.inspect(r.model)?.committed, 0)
            XCTAssertEqual(try Data(contentsOf: r.installed), Data("old".utf8))
            r.hub.onCatalogDownloadAction(.discard, r.model)
        }
        XCTAssertEqual(r.setups, 0); XCTAssertFalse(r.cache.isVerified(r.installed))
        await r.cleanup()
    }
    func testFailedFullSizeMarkupAndSHAUseUnchangedVerifier() async throws {
        for bytes in [Data("short".utf8), Data("<html>bad!!!".utf8), Data("bad-test1234!".utf8)] {
            let r = try DownloadRig(); try Data("old".utf8).write(to: r.installed)
            let script = DownloadScript([.init(status: 200, body: bytes)]), owner = r.owner(script)
            r.hub.onDownloadModel(r.model); await owner.waitForExit()
            XCTAssertEqual(owner.rows[r.model.id]?.phase, .failed)
            XCTAssertEqual(try Data(contentsOf: r.installed), Data("old".utf8)); XCTAssertFalse(r.cache.isVerified(r.installed))
            await r.cleanup()
        }
    }
    func testAppendFlushAndManifestFailuresDoNotCommitAndCrashSuffixIsRefetched() async throws {
        for checkpoint in [CatalogDownloadStorage.Checkpoint.append, .synchronize, .manifest] {
            let r = try DownloadRig(); let script = DownloadScript([r.part(0)]), owner = r.owner(script)
            // Establish a journal before injecting the selected disk failure.
            _ = try owner.storage.prepare(r.model, generation: UUID())
            var manifests = 0
            owner.storage.fault = { point in
                if point == .manifest { manifests += 1 }
                if point == checkpoint && (point != .manifest || manifests > 1) { throw CocoaError(.fileWriteOutOfSpace) }
            }
            r.hub.onDownloadModel(r.model); await owner.waitForExit()
            XCTAssertEqual(try owner.storage.inspect(r.model)?.committed, 0)
            owner.storage.fault = { _ in }
            let nextScript = DownloadScript([r.part(0), r.part(4), r.part(8)]), next = r.owner(nextScript)
            r.hub.onCatalogDownloadAction(.resume, r.model); await next.waitForExit()
        let observed9 = await nextScript.requests
            XCTAssertEqual(observed9.first?.value(forHTTPHeaderField: "Range"), "bytes=0-3")
            XCTAssertEqual(try Data(contentsOf: r.installed), r.bytes)
            await r.cleanup()
        }
    }
    func testCompleteStageRetryAndCrashAfterPublicationAreExplicitAndPassive() async throws {
        for point in [CatalogDownloadStorage.Checkpoint.install, .publication] {
            let r = try DownloadRig(); let script = DownloadScript([r.full]), owner = r.owner(script)
            owner.storage.fault = { if $0 == point { throw CatalogDownloadFailure() } }
            r.hub.onDownloadModel(r.model); await owner.waitForExit()
            XCTAssertEqual(owner.rows[r.model.id]?.phase, .failed); XCTAssertEqual(r.setups, 0)
            XCTAssertEqual(r.cache.isVerified(r.installed), point == .publication)
            let none = DownloadScript([]), recovered = r.owner(none)
        let observed10 = await none.requests
            XCTAssertEqual(observed10.count, 0); XCTAssertEqual(r.setups, 0)
            r.hub.onCatalogDownloadAction(.retry, r.model); await recovered.waitForExit()
            XCTAssertEqual(try Data(contentsOf: r.installed), r.bytes)
        let observed11 = await none.requests
            XCTAssertEqual(observed11.count, 0); XCTAssertEqual(r.setups, 1)
            await r.cleanup()
        }
    }
    func testCaughtInstallMoveFailureRollsBackAndNeverCaches() async throws {
        let r = try DownloadRig(); let script = DownloadScript([r.full])
        let owner = r.owner(script, installer: { stage, model, _, cache in
            // Real installer: same source/destination gets renamed to backup,
            // then the staged move fails and its caught rollback restores it.
            try ModelCatalog.install(staged: stage, as: model, at: stage, cache: cache)
        })
        r.hub.onDownloadModel(r.model); await owner.waitForExit()
        let m = try XCTUnwrap(owner.storage.inspect(r.model))
        XCTAssertEqual(try Data(contentsOf: r.staging.appendingPathComponent(m.staging)), r.bytes)
        XCTAssertEqual(owner.rows[r.model.id]?.phase, .failed); XCTAssertFalse(r.cache.isVerified(r.installed))
        await r.cleanup()
    }
    func testPauseAndDiscardDrainIgnoringCancellationAndTargetExactOwner() async throws {
        let r = try DownloadRig(); let script = DownloadScript([r.part(0), r.part(4, hold: true)])
        let owner = r.owner(script); r.hub.onDownloadModel(r.model); await script.waitForRequests(2)
        let other = ModelCatalog.all[1]
        CatalogDownloadMenuRoute(.pause, other).perform(on: r.hub)
        XCTAssertEqual(owner.activeID, r.model.id)
        CatalogDownloadMenuRoute(.pause, r.model).perform(on: r.hub)
        XCTAssertTrue(owner.isActive); XCTAssertFalse(owner.claimRestartIfIdle())
        r.hub.onCatalogDownloadAction(.discard, r.model)
        XCTAssertNotNil(try owner.storage.inspect(r.model))
        let observed12 = await script.requests
        r.hub.onDownloadModel(r.model); XCTAssertEqual(observed12.count, 2)
        await script.release(); await owner.waitForExit()
        XCTAssertNil(try owner.storage.read(r.model)); XCTAssertNil(owner.rows[r.model.id]); XCTAssertEqual(r.setups, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.installed.path))
        XCTAssertTrue(owner.claimRestartIfIdle())
        await r.cleanup()
    }
    func testUserResumeHasFreshIntentWhileSwitchAwayAndBackRevokesOldIntent() async throws {
        let r = try DownloadRig(); let script = DownloadScript([.init(status: 200, body: r.bytes, hold: true)])
        let owner = r.owner(script); r.hub.onDownloadModel(r.model); await script.waitForRequests(1)
        r.hub.selectModel(ModelCatalog.all[1]); r.hub.selectModel(ModelCatalog.default)
        await script.release(); await owner.waitForExit()
        XCTAssertEqual(r.setups, 0); XCTAssertEqual(try Data(contentsOf: r.installed), r.bytes)
        r.hub.flushPendingSave()
        let next = DownloadScript([r.part(0, hold: true)]), resumed = r.owner(next)
        r.hub.onDownloadModel(r.model); await next.waitForRequests(1)
        r.hub.onCatalogDownloadAction(.pause, r.model); await next.release(); await resumed.waitForExit()
        let finalScript = DownloadScript([r.full]), final = r.owner(finalScript)
        r.hub.onCatalogDownloadAction(.resume, r.model); await final.waitForExit()
        XCTAssertEqual(r.setups, 1); XCTAssertEqual(r.store.load().whisperModelPath, ModelCatalog.path(for: r.model))
        await r.cleanup()
    }
    func testPendingMixedSettingsFlushWithoutLosingPreferencesOrOverwritingNewDiskChoice() async throws {
        for diskChoice in [false, true] {
            let r = try DownloadRig(); let script = DownloadScript([.init(status: 200, body: r.bytes, hold: true)]), owner = r.owner(script)
            r.hub.onDownloadModel(r.model); await script.waitForRequests(1)
            r.hub.settings.showHudAlways = false
            if diskChoice { var s = r.store.load(); s.whisperModelPath = "/user/new.bin"; try r.store.save(s) }
            await script.release(); await owner.waitForExit()
            if diskChoice {
                XCTAssertEqual(r.store.load().whisperModelPath, "/user/new.bin"); XCTAssertEqual(r.setups, 0)
            } else {
                XCTAssertFalse(r.store.load().showHudAlways); XCTAssertEqual(r.setups, 1)
            }
            await r.cleanup()
        }
    }
    func testCorruptSettingsAndSaveFailureNeverSelectOrCallSetup() async throws {
        for corrupt in [false, true] {
            var saves = 0
            let r = try DownloadRig(atomicWrite: { data, url in
                saves += 1
                if !corrupt { throw CocoaError(.fileWriteNoPermission) }
                try data.write(to: url, options: .atomic)
            })
            if corrupt { try Data("invalid settings".utf8).write(to: r.store.url) }
            let script = DownloadScript([r.full]), owner = r.owner(script)
            r.hub.onDownloadModel(r.model); await owner.waitForExit()
            XCTAssertEqual(r.setups, 0); XCTAssertEqual(try Data(contentsOf: r.installed), r.bytes)
            if corrupt { XCTAssertEqual(try String(contentsOf: r.store.url), "invalid settings"); XCTAssertEqual(saves, 0) }
            else { XCTAssertEqual(saves, 1); XCTAssertNotNil(r.hub.downloadError) }
            await r.cleanup()
        }
    }
    func testTerminationWaitsForConcreteDownloadClipboardAndUpdaterOnceAndCancelDoesNotResume() async throws {
        for cancelQuit in [false, true] {
            let r = try DownloadRig(); let script = DownloadScript([r.part(0, hold: true)]), owner = r.owner(script)
            r.hub.onDownloadModel(r.model); await script.waitForRequests(1)
            var clipboard: ((Bool) -> Void)?, update: ((Bool) -> Void)?, replies: [Bool] = []
            let termination = TerminationCoordinator(clipboard: { clipboard = $0 }, updater: { update = $0 },
                download: owner.beginShutdown, cancelDownload: owner.cancelShutdown,
                cancelClipboard: {}, cancelUpdater: {}, reply: { replies.append($0) }, failure: {})
            XCTAssertEqual(termination.request(), .terminateLater)
            update?(true); clipboard?(!cancelQuit)
            XCTAssertEqual(replies, cancelQuit ? [false] : [])
            await script.release(); await owner.waitForExit()
            XCTAssertEqual(replies, [!cancelQuit]); update?(true); clipboard?(true)
            XCTAssertEqual(replies, [!cancelQuit]); XCTAssertEqual(owner.rows[r.model.id]?.phase, .paused)
        let observed13 = await script.requests
            XCTAssertEqual(observed13.count, 1); XCTAssertEqual(r.setups, 0)
            await r.cleanup()
        }
    }
}

extension CatalogDownloadTests {
    func testReopenTruncatesOnlyUncommittedOwnedSuffixAndRefetches() async throws {
        let r = try DownloadRig(); let script = DownloadScript([r.part(0), .init(fail: true)]), owner = r.owner(script)
        r.hub.onDownloadModel(r.model); await owner.waitForExit()
        let m = try XCTUnwrap(owner.storage.inspect(r.model))
        let stage = r.staging.appendingPathComponent(m.staging)
        let file = try FileHandle(forWritingTo: stage); try file.seekToEnd(); try file.write(contentsOf: Data("junk".utf8)); try file.synchronize(); try file.close()
        XCTAssertEqual(try Data(contentsOf: stage).count, 8)
        let next = DownloadScript([r.part(4), r.part(8)]), recovered = r.owner(next)
        r.hub.onCatalogDownloadAction(.resume, r.model); await recovered.waitForExit()
        XCTAssertEqual(try Data(contentsOf: r.installed), r.bytes)
        let requests = await next.requests
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Range"), "bytes=4-7")
        await r.cleanup()
    }
    func testMissingShortOvercapLinkedSymlinkAndEscapingStagingRefuseWithoutUnknownDeletion() async throws {
        for mutation in ["missing", "short", "overcap", "symlink", "hardlink", "escape", "manifest-link", "manifest-symlink", "manifest-overcap", "malformed", "file-count"] {
            let r = try DownloadRig(); try Data("old".utf8).write(to: r.installed)
            let script = DownloadScript([r.part(0), .init(fail: true)]), owner = r.owner(script)
            r.hub.onDownloadModel(r.model); await owner.waitForExit()
            let m = try XCTUnwrap(owner.storage.inspect(r.model))
            let stage = r.staging.appendingPathComponent(m.staging)
            let manifest = r.staging.appendingPathComponent(r.model.id + ".json")
            let unknown = r.root.appendingPathComponent("unknown-user-file")
            try Data("private user bytes".utf8).write(to: unknown)
            switch mutation {
            case "missing": try FileManager.default.removeItem(at: stage)
            case "short": try Data("g".utf8).write(to: stage)
            case "overcap": try Data(repeating: 1, count: 13).write(to: stage)
            case "symlink":
                try FileManager.default.removeItem(at: stage)
                try FileManager.default.createSymbolicLink(at: stage, withDestinationURL: unknown)
            case "hardlink": try FileManager.default.linkItem(at: stage, to: r.root.appendingPathComponent("linked-stage"))
            case "manifest-link": try FileManager.default.linkItem(at: manifest, to: r.root.appendingPathComponent("linked-manifest"))
            case "manifest-symlink":
                try FileManager.default.removeItem(at: manifest)
                try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: unknown)
            case "manifest-overcap": try Data(repeating: 32, count: 4097).write(to: manifest)
            case "malformed": try Data("invalid".utf8).write(to: manifest)
            case "file-count":
                for i in 0..<17 { try Data([1]).write(to: r.staging.appendingPathComponent("unknown-\(i)")) }
            default:
                var object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: NSObject]
                object["staging"] = "../installed.bin" as NSString
                try JSONSerialization.data(withJSONObject: object).write(to: manifest)
            }
            let next = DownloadScript([]), recovered = r.owner(next)
            XCTAssertEqual(recovered.rows[r.model.id]?.phase, .failed, mutation)
            r.hub.onCatalogDownloadAction(.resume, r.model); await recovered.waitForExit()
            let requests = await next.requests
            XCTAssertEqual(requests.count, 0, mutation)
            r.hub.onCatalogDownloadAction(.discard, r.model)
            XCTAssertEqual(try Data(contentsOf: unknown), Data("private user bytes".utf8), mutation)
            XCTAssertEqual(try Data(contentsOf: r.installed), Data("old".utf8), mutation)
            XCTAssertEqual(r.setups, 0)
            await r.cleanup()
        }
    }
    func testChangedCanonicalArtifactRefusesResumeAndOnlyExplicitDiscardRetiresOwnedState() async throws {
        let r = try DownloadRig(); let first = DownloadScript([r.part(0), .init(fail: true)]), owner = r.owner(first)
        r.hub.onDownloadModel(r.model); await owner.waitForExit()
        let changed = ModelCatalog.Model(id: r.model.id, displayName: "Changed fixture", bytes: r.model.bytes, sha256: String(repeating: "b", count: 64))
        let script = DownloadScript([]), recovered = r.owner(script, model: changed)
        r.hub.onCatalogDownloadAction(.resume, changed); await recovered.waitForExit()
        XCTAssertEqual(recovered.rows[changed.id]?.phase, .failed)
        let requests = await script.requests
        XCTAssertTrue(requests.isEmpty)
        let unknown = r.staging.appendingPathComponent("user-file")
        try Data("untouched".utf8).write(to: unknown)
        r.hub.onCatalogDownloadAction(.discard, changed)
        XCTAssertNil(try recovered.storage.read(changed))
        XCTAssertEqual(try String(contentsOf: unknown), "untouched")
        await r.cleanup()
    }
    func testBackupCrashFixtureKeepsOldBackupUntilExplicitVerifiedHandoff() async throws {
        let r = try DownloadRig(); let script = DownloadScript([r.full]), owner = r.owner(script)
        owner.storage.fault = { if $0 == .install { throw CatalogDownloadFailure() } }
        r.hub.onDownloadModel(r.model); await owner.waitForExit()
        let backup = r.installed.appendingPathExtension("backup")
        try Data("previous installed bytes".utf8).write(to: backup)
        let none = DownloadScript([]), recovered = r.owner(none)
        XCTAssertEqual(try String(contentsOf: backup), "previous installed bytes")
        XCTAssertFalse(r.cache.isVerified(r.installed)); XCTAssertEqual(r.setups, 0)
        r.hub.onCatalogDownloadAction(.resume, r.model); await recovered.waitForExit()
        XCTAssertEqual(try Data(contentsOf: r.installed), r.bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        // This fixture defines recovery through the existing installer. It is
        // not a power-loss atomicity guarantee for its backup/move sequence.
        await r.cleanup()
    }
    func testHeldInstallOwnsQuitAndRestartUntilActualExitWithNoSelectionAfterPause() async throws {
        let r = try DownloadRig(), entered = expectation(description: "real install entered")
        let release = DispatchSemaphore(value: 0)
        let script = DownloadScript([r.full])
        let owner = r.owner(script, installer: { stage, model, destination, cache in
            entered.fulfill(); release.wait()
            try ModelCatalog.install(staged: stage, as: model, at: destination, cache: cache)
        })
        r.hub.onDownloadModel(r.model); await fulfillment(of: [entered], timeout: 5)
        XCTAssertFalse(owner.claimRestartIfIdle())
        var replies: [Bool] = []
        owner.beginShutdown { replies.append($0) }
        XCTAssertTrue(replies.isEmpty); XCTAssertTrue(owner.isActive)
        release.signal(); await owner.waitForExit()
        XCTAssertEqual(replies, [true]); XCTAssertEqual(r.setups, 0)
        XCTAssertEqual(try Data(contentsOf: r.installed), r.bytes)
        XCTAssertTrue(owner.claimRestartIfIdle())
        await r.cleanup()
    }
    func testPausedOwnerDoesNotBlockRestartOrResumeAfterRestartClaim() async throws {
        let r = try DownloadRig(), script = DownloadScript([r.part(0, hold: true)])
        let owner = r.owner(script); r.hub.onDownloadModel(r.model); await script.waitForRequests(1)
        r.hub.onCatalogDownloadAction(.pause, r.model); await script.release(); await owner.waitForExit()
        XCTAssertEqual(owner.rows[r.model.id]?.phase, .paused); XCTAssertTrue(owner.claimRestartIfIdle())
        r.hub.onCatalogDownloadAction(.resume, r.model)
        let requests = await script.requests
        XCTAssertEqual(requests.count, 1); XCTAssertFalse(owner.isActive)
        await r.cleanup()
    }
    func testUpdaterFailureReleasesRestartReservationWithoutReleasingPendingQuit() async throws {
        for pendingQuit in [false, true] {
            let r = try DownloadRig(), script = DownloadScript([])
            let owner = r.owner(script)
            XCTAssertTrue(owner.claimRestartIfIdle())
            let update = UpdateTerminationIntent()
            var replies: [Bool] = []
            if pendingQuit {
                owner.beginShutdown { XCTAssertTrue($0) }
                update.request(waitingForInstall: true, committing: true,
                    cancelInstall: { XCTFail("An accepted commit must drain") },
                    reply: { replies.append($0) })
            }
            XCTAssertEqual(update.installFailed(releaseRestart: owner.releaseRestartReservation), pendingQuit)
            XCTAssertEqual(replies, pendingQuit ? [true] : [])
            update.complete()
            XCTAssertEqual(replies, pendingQuit ? [true] : [])
            r.hub.onDownloadModel(r.model)
            XCTAssertEqual(owner.isActive, !pendingQuit)
            if pendingQuit {
                owner.cancelShutdown()
                r.hub.onDownloadModel(r.model)
                XCTAssertTrue(owner.isActive)
            }
            await owner.waitForExit()
            let requests = await script.requests
            XCTAssertEqual(requests.count, 1)
            await r.cleanup()
        }
    }
}

private final class DownloadURLProtocol: URLProtocol {
    static var handle: (DownloadURLProtocol) -> Void = { _ in }
    static var stopped: () -> Void = {}
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handle(self) }
    override func stopLoading() { Self.stopped() }
    func send(_ response: URLResponse, chunks: [Data]) {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for data in chunks { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
}

extension CatalogDownloadTests {
    private func adapter() -> CatalogURLSessionTransport {
        CatalogURLSessionTransport(configuration: {
            let c = URLSessionConfiguration.ephemeral
            c.protocolClasses = [DownloadURLProtocol.self]
            c.httpCookieStorage = nil; c.urlCredentialStorage = nil; c.urlCache = nil
            return c
        })
    }
    func testActualDiskAdapterFull200AndMatchingRangeRequestsWithoutNetwork() async throws {
        for range in [false, true] {
            let r = try DownloadRig()
            DownloadURLProtocol.handle = { stub in
                let header = stub.request.value(forHTTPHeaderField: "Range")!
                XCTAssertEqual(stub.request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
                if range {
                    let start = Int(header.dropFirst(6).split(separator: "-")[0])!
                    let reply = r.part(start)
                    stub.send(HTTPURLResponse(url: stub.request.url!, statusCode: 206, httpVersion: nil, headerFields: reply.headers)!, chunks: [reply.body])
                } else {
                    stub.send(HTTPURLResponse(url: stub.request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "12"])!, chunks: [r.bytes.prefix(5), r.bytes.suffix(7)])
                }
            }
            let owner = r.owner(adapter()); r.hub.onDownloadModel(r.model); await owner.waitForExit()
            XCTAssertEqual(try Data(contentsOf: r.installed), r.bytes); XCTAssertEqual(r.setups, 1)
            DownloadURLProtocol.handle = { _ in }
            await r.cleanup()
        }
    }
    func testActualAdapterBoundsNonHTTPErrorEncodingAndUntrustedFinalURL() async throws {
        for variant in ["overlong200", "overlong206", "advertised-overcap", "nonHTTP", "error", "encoding", "multipart", "insecure", "foreign"] {
            let r = try DownloadRig()
            DownloadURLProtocol.handle = { stub in
                var url = stub.request.url!, status = 200, headers: [String: String] = [:], data = r.bytes
                switch variant {
                case "overlong200": data.append(1)
                case "overlong206": status = 206; headers["Content-Range"] = "bytes 0-3/12"; data = Data("ggmlx".utf8)
                case "advertised-overcap": headers["Content-Length"] = "999"
                case "nonHTTP":
                    stub.send(URLResponse(url: url, mimeType: nil, expectedContentLength: 12, textEncodingName: nil), chunks: [data]); return
                case "error": status = 503
                case "encoding": headers["Content-Encoding"] = "gzip"
                case "multipart": headers["Content-Type"] = "multipart/byteranges"
                case "insecure": url = URL(string: "http://huggingface.co/model")!
                default: url = URL(string: "https://untrusted.example/model")!
                }
                stub.send(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!, chunks: [data])
            }
            let owner = r.owner(adapter()); r.hub.onDownloadModel(r.model); await owner.waitForExit()
            XCTAssertEqual(owner.rows[r.model.id]?.phase, .failed, variant)
            XCTAssertEqual(try owner.storage.inspect(r.model)?.committed, 0, variant)
            XCTAssertFalse(FileManager.default.fileExists(atPath: r.installed.path))
            DownloadURLProtocol.handle = { _ in }
            await r.cleanup()
        }
    }
    func testActualAdapterCancellationWaitsForStoppedWriterBeforeDiscard() async throws {
        let r = try DownloadRig(), started = expectation(description: "adapter started"), stopped = expectation(description: "adapter stopped")
        DownloadURLProtocol.handle = { _ in started.fulfill() }
        DownloadURLProtocol.stopped = { stopped.fulfill() }
        let owner = r.owner(adapter()); r.hub.onDownloadModel(r.model)
        await fulfillment(of: [started], timeout: 5)
        r.hub.onCatalogDownloadAction(.discard, r.model)
        await owner.waitForExit(); await fulfillment(of: [stopped], timeout: 5)
        XCTAssertNil(try owner.storage.read(r.model)); XCTAssertEqual(r.setups, 0)
        DownloadURLProtocol.handle = { _ in }; DownloadURLProtocol.stopped = {}
        await r.cleanup()
    }
    func testHTTPSRedirectPolicyAllowsFreshSignedCDNAndRefusesCredentialsDowngradeAndForeignHost() async throws {
        let r = try DownloadRig()
        DownloadURLProtocol.handle = { stub in
            let final = URL(string: "https://cdn-lfs.hf.co/model?signature=TEST_ONLY_TRANSIENT")!
            stub.send(HTTPURLResponse(url: final, statusCode: 200, httpVersion: nil, headerFields: [:])!, chunks: [r.bytes])
        }
        let owner = r.owner(adapter()); r.hub.onDownloadModel(r.model); await owner.waitForExit()
        XCTAssertEqual(try Data(contentsOf: r.installed), r.bytes)
        for text in ["http://cdn-lfs.hf.co/m", "https://huggingface.co.evil.example/m", "https://user:pass@huggingface.co/m", "https://huggingface.co:444/m", "https://example.com/m"] {
            XCTAssertFalse(CatalogURLSessionTransport.permitsRedirect(URL(string: text)!))
        }
        XCTAssertTrue(CatalogURLSessionTransport.permitsRedirect(URL(string: "https://cas-bridge.xethub.hf.co/m?fresh=1")!))
        DownloadURLProtocol.handle = { _ in }
        await r.cleanup()
    }
}

private final class DownloadEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [@MainActor () -> Void] = []
    func enqueue(_ event: @escaping @MainActor () -> Void) {
        lock.lock(); events.append(event); lock.unlock()
    }
    @MainActor func flush() {
        lock.lock(); let pending = events; events = []; lock.unlock()
        pending.forEach { $0() }
    }
}

extension CatalogDownloadTests {
    func testLateProgressFromPreviousGenerationCannotClearNewTaskOrError() async throws {
        let r = try DownloadRig(), events = DownloadEvents()
        let script = DownloadScript([r.full, .init(status: 200, body: r.bytes, hold: true)])
        let owner = CatalogDownloadOwner(root: r.staging, catalog: [r.model], transport: script, chunkBytes: 4,
            destination: { _ in r.installed }, cache: r.cache, enqueueProgress: events.enqueue)
        r.owners.append(owner); r.hub.bindCatalogDownloads(owner, setup: { r.setups += 1 })
        r.hub.onDownloadModel(r.model); await owner.waitForExit()
        r.hub.onDownloadModel(r.model); await script.waitForRequests(2)
        r.hub.downloadError = "New action's error"
        events.flush()
        XCTAssertEqual(owner.rows[r.model.id]?.phase, .downloading)
        XCTAssertEqual(owner.rows[r.model.id]?.percent, 0)
        XCTAssertEqual(r.hub.downloadError, "New action's error"); XCTAssertTrue(owner.isActive)
        await script.release(); await owner.waitForExit(); events.flush()
        XCTAssertEqual(owner.rows[r.model.id]?.phase, .installed)
        await r.cleanup()
    }
    func testActualB25ProviderAndB57ShutdownWrapperWaitForDownloadAndUpdater() async throws {
        let r = try DownloadRig(), script = DownloadScript([r.part(0, hold: true)])
        let owner = r.owner(script); r.hub.onDownloadModel(r.model); await script.waitForRequests(1)
        let clipboard = ExperimentRig(); XCTAssertTrue(clipboard.paste())
        let provider = clipboard.current.provider
        var updates: ((Bool) -> Void)?, replies: [Bool] = []
        let undo = CanceledCaptureUndoController(configuration: { nil }, generation: { 0 }, security: { .unavailable }, copy: { _ in })
        let coordinator = TerminationCoordinator(clipboard: clipboard.delivery.beginShutdown, updater: { updates = $0 },
            download: owner.beginShutdown, cancelDownload: owner.cancelShutdown,
            cancelClipboard: clipboard.delivery.cancelShutdown, cancelUpdater: {}, reply: { replies.append($0) }, failure: { XCTFail("unexpected quit failure") })
        let wrapper = CanceledCaptureTermination(undo: undo, coordinator: coordinator)
        XCTAssertEqual(wrapper.request(), .terminateLater)
        updates?(true)
        XCTAssertTrue(clipboard.current.provider === provider); XCTAssertTrue(clipboard.delivery.isRestorePending)
        await script.release(); await owner.waitForExit(); XCTAssertTrue(replies.isEmpty)
        clipboard.fire(clipboard.timers[0]); clipboard.flush()
        XCTAssertEqual(replies, [true]); updates?(true); XCTAssertEqual(replies, [true])
        XCTAssertEqual(r.setups, 0); XCTAssertEqual(owner.rows[r.model.id]?.phase, .paused)
        await r.cleanup()
    }
    func testRejectedCompleteBytesRetryDownloadsAgainWithoutTouchingOldModel() async throws {
        let r = try DownloadRig(); try Data("old".utf8).write(to: r.installed)
        let script = DownloadScript([.init(status: 200, body: Data("bad-test1234!".utf8)), r.full]), owner = r.owner(script)
        r.hub.onDownloadModel(r.model); await owner.waitForExit()
        XCTAssertEqual(try owner.storage.inspect(r.model)?.committed, 0)
        XCTAssertEqual(try Data(contentsOf: r.installed), Data("old".utf8)); XCTAssertFalse(r.cache.isVerified(r.installed))
        r.hub.onCatalogDownloadAction(.retry, r.model); await owner.waitForExit()
        XCTAssertEqual(try Data(contentsOf: r.installed), r.bytes); XCTAssertTrue(r.cache.isVerified(r.installed))
        await r.cleanup()
    }
}

extension CatalogDownloadTests {
    func testPassiveHubPathAdoptionDuringDownloadPreservesFreshExplicitIntent() async throws {
        let r = try DownloadRig()
        var initial = r.store.load(); initial.whisperModelPath = "/previous/model.bin"; try r.store.save(initial)
        let script = DownloadScript([.init(status: 200, body: r.bytes, hold: true)]), owner = r.owner(script)
        r.hub.onDownloadModel(r.model); await script.waitForRequests(1)
        // Uses the production loading/adoption path without invoking permission
        // probes, credential migration, model setup or a live Hub window.
        r.hub.adoptModelPath(initial.whisperModelPath!)
        await script.release(); await owner.waitForExit()
        XCTAssertEqual(r.store.load().whisperModelPath, ModelCatalog.path(for: r.model)); XCTAssertEqual(r.setups, 1)
        await r.cleanup()
    }
}

extension CatalogDownloadTests {
    func testFileCapacityIsReservedBeforeCreatingOwnedFilesAndUnknownEntriesStayIntact() async throws {
        for count in [14, 15, 16] {
            let r = try DownloadRig()
            try FileManager.default.createDirectory(at: r.staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for i in 0..<count { try Data([UInt8(i)]).write(to: r.staging.appendingPathComponent("unknown-\(i)")) }
            let script = DownloadScript([]), owner = r.owner(script)
            r.hub.onDownloadModel(r.model); await owner.waitForExit()
            XCTAssertEqual(owner.rows[r.model.id]?.phase, .failed)
            let entries = try FileManager.default.contentsOfDirectory(atPath: r.staging.path)
            XCTAssertLessThanOrEqual(entries.count, 16)
            let requests = await script.requests
            XCTAssertTrue(requests.isEmpty)
            r.hub.onCatalogDownloadAction(.discard, r.model)
            for i in 0..<count { XCTAssertEqual(try Data(contentsOf: r.staging.appendingPathComponent("unknown-\(i)")), Data([UInt8(i)])) }
            await r.cleanup()
        }
    }
}

extension CatalogDownloadTests {
    func testPauseDuringFlushedAppendRevokesJournalCommitAndResumeRefetchesChunk() async throws {
        let r = try DownloadRig(), appended = expectation(description: "chunk appended before synchronization")
        let exit = DispatchSemaphore(value: 0)
        let script = DownloadScript([r.part(0), r.full]), owner = r.owner(script)
        owner.storage.fault = { point in
            if point == .synchronize { appended.fulfill(); exit.wait() }
        }
        r.hub.onDownloadModel(r.model); await fulfillment(of: [appended], timeout: 5)
        r.hub.onCatalogDownloadAction(.pause, r.model)
        exit.signal(); await owner.waitForExit()
        XCTAssertEqual(try owner.storage.inspect(r.model)?.committed, 0)
        XCTAssertEqual(owner.rows[r.model.id]?.phase, .paused); XCTAssertEqual(r.setups, 0)
        owner.storage.fault = { _ in }
        r.hub.onCatalogDownloadAction(.resume, r.model); await owner.waitForExit()
        let requests = await script.requests
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Range"), "bytes=0-3")
        XCTAssertEqual(try Data(contentsOf: r.installed), r.bytes); XCTAssertEqual(r.setups, 1)
        await r.cleanup()
    }
}

extension CatalogDownloadTests {
    func testFreshDownloadIntentSupersedesOnlySelectionDraftThatPredatesIt() async throws {
        for flushBeforeCompletion in [false, true] {
            let r = try DownloadRig()
            r.hub.selectModel(ModelCatalog.all[1])
            let script = DownloadScript([.init(status: 200, body: r.bytes, hold: true)]), owner = r.owner(script)
            r.hub.onDownloadModel(r.model); await script.waitForRequests(1)
            if flushBeforeCompletion { r.hub.flushPendingSave() }
            await script.release(); await owner.waitForExit()
            XCTAssertEqual(r.store.load().whisperModelPath, ModelCatalog.path(for: r.model))
            XCTAssertEqual(r.setups, 1)
            await r.cleanup()
        }
    }
}

extension CatalogDownloadTests {
    func testPreparationRestartAndQuitComposeWithActiveThenPausedDownloadWithoutResumption() async throws {
        let r = try DownloadRig(), p = try PreparationAppRig()
        let script = DownloadScript([r.part(0, hold: true)]), download = r.owner(script)
        download.act(.download, model: r.model); await script.waitForRequests(1)
        var rejected = 0
        let first = await p.owner.claimRestart(chain: { p.chain }, allowed: { !download.isActive },
            claimOther: download.claimRestartIfIdle, rejected: { rejected += 1 })
        XCTAssertFalse(first); XCTAssertEqual(rejected, 1)
        _ = try await p.factory.acquire(request: p.request, operation: PendingOperation(name: "fresh after rejected claim"))
        var replies: [Bool] = []
        let done = expectation(description: "download and prep quit settled")
        let coordinator = TerminationCoordinator(clipboard: { $0(true) }, updater: { $0(true) },
            download: download.beginShutdown, cancelDownload: download.cancelShutdown,
            preparation: { p.owner.beginShutdown(chain: { p.chain }, reply: $0) }, cancelPreparation: p.owner.cancelShutdown,
            cancelClipboard: {}, cancelUpdater: {}, reply: { replies.append($0); done.fulfill() }, failure: {})
        XCTAssertEqual(coordinator.request(), .terminateLater)
        await script.release(); await download.waitForExit()
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(replies, [true]); XCTAssertEqual(download.rows[r.model.id]?.phase, .paused)
        let requests = await script.requests
        download.cancelShutdown(); p.owner.cancelShutdown()
        let accepted = await p.owner.claimRestart(chain: { p.chain }, allowed: { !download.isActive },
            claimOther: download.claimRestartIfIdle, rejected: { rejected += 1 })
        XCTAssertTrue(accepted)
        let update = UpdateTerminationIntent()
        XCTAssertFalse(update.installFailed(releaseRestart: { download.releaseRestartReservation(); p.owner.core.releaseRestart() }))
        let after = await script.requests.count
        XCTAssertEqual(after, requests.count)
        await r.cleanup(); try await p.close()
    }
}

// B22's additive participant composes with these existing concrete owners;
// only native generation and catalog transport are held fake bottom APIs.
extension CatalogDownloadTests {
    func testLocalCleanupDrainComposesWithActualClipboardDownloadPreparationAndUndo() async throws {
        for enabled in [false, true] {
            let local = try LocalAppRig(), prep = try PreparationAppRig(enabled: enabled), catalog = try DownloadRig()
            let script = DownloadScript([catalog.part(0, hold: true)]), download = catalog.owner(script)
            download.act(.download, model: catalog.model); await script.waitForRequests(1)
            let clipboard = ExperimentRig(); XCTAssertTrue(clipboard.paste())
            let provider = clipboard.current.provider, entry = local.row()
            local.bottom.hold = true; local.bottom.started = expectation(description: "local session held")
            local.hub.prepareHistoryRetry(entry.id)
            let request = Task { await local.hub.startHistoryRetry(entry.id) }
            await fulfillment(of: [local.bottom.started!], timeout: 2)
            let prepExit = expectation(description: "preparation participant drained")
            var update: ((Bool) -> Void)?, replies: [Bool] = []
            let replied = expectation(description: "all concrete owners drained")
            let coordinator = TerminationCoordinator(clipboard: clipboard.delivery.beginShutdown, updater: { update = $0 },
                download: download.beginShutdown, cancelDownload: download.cancelShutdown,
                preparation: { done in prep.owner.beginShutdown(chain: { local.chain }, reply: { allowed in prepExit.fulfill(); done(allowed) }) },
                cancelPreparation: prep.owner.cancelShutdown,
                localCleanup: { local.admission.beginShutdown(chain: { local.chain }, reply: $0) }, cancelLocalCleanup: local.admission.cancelShutdown,
                cancelClipboard: clipboard.delivery.cancelShutdown, cancelUpdater: {},
                reply: { replies.append($0); replied.fulfill() }, failure: { XCTFail("unexpected drain failure") })
            let undo = CanceledCaptureUndoController(configuration: { nil }, generation: { 0 }, security: { .unavailable }, copy: { _ in XCTFail("Unexpected copy") })
            let quit = CanceledCaptureTermination(undo: undo, coordinator: coordinator)
            XCTAssertEqual(quit.request(), .terminateLater)
            XCTAssertTrue(clipboard.current.provider === provider); XCTAssertTrue(clipboard.delivery.isRestorePending)
            XCTAssertTrue(local.hub.historyRetries[entry.id]!.operation.shouldAbort)
            XCTAssertFalse(local.admission.admit(PendingOperation(name: "late local")))
            local.bottom.release(); await request.value; await local.chain?.value
            await fulfillment(of: [prepExit], timeout: 2)
            XCTAssertTrue(replies.isEmpty); XCTAssertNil(local.hub.historyRetries[entry.id]?.proposed)
            await script.release(); await download.waitForExit()
            XCTAssertEqual(download.rows[catalog.model.id]?.phase, .paused); XCTAssertEqual(catalog.setups, 0)
            update?(true); XCTAssertTrue(replies.isEmpty)
            clipboard.fire(clipboard.timers[0]); clipboard.flush()
            await fulfillment(of: [replied], timeout: 2)
            update?(true); XCTAssertEqual(replies, [true]); XCTAssertEqual(local.bottom.counts.generation, 1)
            await catalog.cleanup(); try await prep.close(); try await local.close()
        }
    }
}

/// An explicit test parent crosses SwiftPM/XCTest without relying on TMPDIR.
/// With no override, ordinary test execution retains Foundation's temp default.
private enum DownloadTestPaths {
    static let parentKey = "PARLA_CATALOG_TEST_PARENT"
    static func parent(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        guard let path = environment[parentKey] else {
            return FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        }
        guard path.hasPrefix("/") else { throw CatalogDownloadFailure() }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw CatalogDownloadFailure() }
        return url.resolvingSymlinksInPath()
    }
    static func validateLeaf(_ url: URL, parent: URL) throws {
        var info = stat()
        guard url.deletingLastPathComponent().path == parent.path, url.resolvingSymlinksInPath().path == url.path,
              lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw CatalogDownloadFailure() }
    }
}

/// File-backed child output avoids pipe deadlock. Every launched child is joined
/// before this helper returns or throws; evidence directories survive failures.
@MainActor
private enum DownloadProcessEvidence {
    static let roleKey = "PARLA_CATALOG_PROCESS_TEST_ROLE"
    static let nonceKey = "PARLA_CATALOG_PROCESS_TEST_NONCE"
    static let rootKey = "PARLA_CATALOG_PROCESS_TEST_ROOT"

    static func reentry(environment: [String: String], parent: URL) throws -> (String, String, URL)? {
        let keys = [roleKey, nonceKey, rootKey]
        guard keys.contains(where: { environment[$0] != nil }) else { return nil }
        guard let role = environment[roleKey], ["checkpoint", "resume"].contains(role),
              let nonce = environment[nonceKey], UUID(uuidString: nonce) != nil,
              let path = environment[rootKey], path.hasPrefix("/") else { throw CatalogDownloadFailure() }
        let root = URL(fileURLWithPath: path)
        guard root.path == parent.appendingPathComponent("download-process-child-" + nonce).path else { throw CatalogDownloadFailure() }
        try DownloadTestPaths.validateLeaf(root, parent: parent)
        return (role, nonce, root)
    }
    struct Environment: Codable {
        let assignedParent: String?, effectiveParent: String, foundationTemp: String
        let tmpdir: String?, manifest: String?
        init(values: [String: String], parent: URL) {
            assignedParent = values[DownloadTestPaths.parentKey]; effectiveParent = parent.path
            foundationTemp = FileManager.default.temporaryDirectory.path
            tmpdir = values["TMPDIR"]; manifest = values["PARLA_TEST_FIXTURE_MANIFEST"]
        }
    }
    struct Phase: Codable {
        let role: String, nonce: String
        let pid: Int32, parentPID: Int32
        let environment: Environment
        let root: String
        let modelBytes: Int64
        let sha256: String
        let committed: Int64
        let stageIdentity: String
        let passiveRequests: Int
        let ranges: [String], ifRanges: [String?]
        let installedBytes: Int
        let installedSHA256: String
        let cacheVerified: Bool
        let setups: Int
        let selectedPath: String?
    }
    struct Run: Codable {
        let role: String, nonce: String, runner: String
        let environment: Environment
        let arguments: [String]
        let pid: Int32
        let started: TimeInterval, exited: TimeInterval
        let status: Int32, reason: String
        let waited: Bool, outputHandlesClosed: Bool
        let failure: String?
    }
    static func identity(_ url: URL) throws -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw CatalogDownloadFailure() }
        return "\(info.st_dev):\(info.st_ino)"
    }
    static func run(role: String, nonce: String, root: URL, runner: URL, arguments: [String]) async throws -> Run {
        let parent = try DownloadTestPaths.parent()
        try DownloadTestPaths.validateLeaf(root, parent: parent)
        let output = root.appendingPathComponent(role + ".stdout")
        let error = root.appendingPathComponent(role + ".stderr")
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              FileManager.default.createFile(atPath: error.path, contents: nil) else { throw CatalogDownloadFailure() }
        let stdout = try FileHandle(forWritingTo: output)
        let stderr = try FileHandle(forWritingTo: error)
        defer { try? stdout.close(); try? stderr.close() }
        let child = Process()
        child.executableURL = runner
        child.arguments = arguments
        child.environment = ProcessInfo.processInfo.environment.merging(
            [roleKey: role, nonceKey: nonce, rootKey: root.path, DownloadTestPaths.parentKey: parent.path], uniquingKeysWith: { _, new in new })
        child.standardOutput = stdout; child.standardError = stderr
        let started = ProcessInfo.processInfo.systemUptime
        var launched = false
        var failure: Error?
        do {
            try Task.checkCancellation()
            try child.run()
            launched = true
            while child.isRunning {
                guard ProcessInfo.processInfo.systemUptime - started < 60 else { throw CatalogDownloadFailure() }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            try Task.checkCancellation()
        } catch {
            failure = error
            if launched && child.isRunning {
                child.terminate()
                // Only the exact owned child is killed; it cannot recurse or
                // launch helpers. Joining follows even on test cancellation.
                kill(child.processIdentifier, SIGKILL)
            }
        }
        if launched { child.waitUntilExit() }
        try stdout.close(); try stderr.close()
        let receipt = Run(role: role, nonce: nonce, runner: runner.path, environment: .init(values: ProcessInfo.processInfo.environment, parent: parent), arguments: arguments,
            pid: launched ? child.processIdentifier : 0, started: started, exited: ProcessInfo.processInfo.systemUptime,
            status: launched ? child.terminationStatus : -1,
            reason: launched ? String(describing: child.terminationReason) : "not-launched",
            waited: launched, outputHandlesClosed: true, failure: failure.map { String(describing: $0) })
        try JSONEncoder().encode(receipt).write(to: root.appendingPathComponent(role + "-process.json"), options: .atomic)
        if let failure { throw failure }
        guard receipt.status == 0, child.terminationReason == .exit else {
            XCTFail("\(role) child failed: \(receipt.status), \(receipt.reason); evidence: \(root.path)")
            throw CatalogDownloadFailure()
        }
        let phase = try JSONDecoder().decode(Phase.self, from: Data(contentsOf: root.appendingPathComponent(role + ".json")))
        guard phase.pid == receipt.pid, phase.parentPID == getpid(), phase.role == role, phase.nonce == nonce else {
            throw CatalogDownloadFailure()
        }
        return receipt
    }
}
