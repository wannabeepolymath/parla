import Foundation
import Security
import XCTest
@testable import ParlaCore

final class UpdateInstallerTests: XCTestCase {
    private struct Boom: Error {}
    private var root: URL!
    private var installed: URL!   // the app being replaced
    private var volume: URL!      // stands in for the mounted DMG
    private var stagings: [URL] = []
    private var calls: [String] = []

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateInstallerTests-\(UUID().uuidString)")
        installed = root.appendingPathComponent("Applications/Parla.app")
        volume = root.appendingPathComponent("volume")
        makeApp(at: installed, version: "0.5.0")
        makeApp(at: volume.appendingPathComponent("Parla.app"), version: "0.6.0")
    }

    override func tearDown() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeApp(at app: URL, version: String) {
        let contents = app.appendingPathComponent("Contents")
        try? FileManager.default.removeItem(at: app)
        try! FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: NSDictionary = ["CFBundleShortVersionString": version]
        XCTAssertTrue(plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true))
    }

    private func version(_ app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    /// Every side effect recorded in `calls`; `failing` names the one that throws.
    private func installer(failing: String? = nil, safeAfter: Int = 0,
                           swap: ((URL, URL) throws -> Void)? = nil,
                           sleep: ((TimeInterval) async throws -> Void)? = nil,
                           onVerify: (() -> Void)? = nil) -> UpdateInstaller {
        var claims = 0
        let step = { (name: String) throws in
            self.calls.append(name)
            if name == failing { throw Boom() }
        }
        return UpdateInstaller(
            download: { _, file in try step("download"); try Data("dmg".utf8).write(to: file) },
            attach: { _, _ in try step("attach"); return .init(device: "/dev/disk9", point: self.volume) },
            detach: { _ in try step("detach") },
            verify: { _ in try step("verify"); onVerify?() },
            swap: { staged, target in try step("swap"); try (swap ?? UpdateInstaller.exchange)(staged, target) },
            relaunch: { _ in try step("relaunch") },
            claimRestart: {
                self.calls.append("claim")
                claims += 1
                return claims > safeAfter
            },
            sleep: { seconds in self.calls.append("sleep"); try await sleep?(seconds) },
            stagingDirectory: { _ in
                let dir = self.root.appendingPathComponent("staging-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                self.stagings.append(dir)
                return dir
            })
    }

    private func install(_ installer: UpdateInstaller) async -> Result<UpdateInstaller.Installed, UpdateInstaller.Failure> {
        do {
            return .success(try await installer.install(dmg: URL(string: "https://example.invalid/Parla-0.6.0.dmg")!,
                                                         currentVersion: "0.5.0", at: installed))
        } catch let failure as UpdateInstaller.Failure {
            return .failure(failure)
        } catch {
            XCTFail("not a Failure: \(error)")
            return .failure(.init(step: .download, reason: "\(error)"))
        }
    }

    private func assertStagingRemoved(file: StaticString = #filePath, line: UInt = #line) {
        for dir in stagings { XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), file: file, line: line) }
    }

    // MARK: - Transaction

    func testStepsRunInOrderAndTheNewAppReplacesTheOld() async {
        let result = await install(installer())
        XCTAssertEqual(try result.get(), .relaunching)
        XCTAssertEqual(calls, ["download", "attach", "detach", "verify", "claim", "swap", "relaunch"])
        XCTAssertEqual(version(installed), "0.6.0")
        assertStagingRemoved() // the old app went with it
    }

    func testCleanupRunsOnFailureAtEveryStep() async throws {
        let cases: [(failing: String, step: UpdateInstaller.Step, detaches: Int)] = [
            ("download", .download, 0), ("attach", .mount, 0), ("verify", .verify, 1), ("swap", .commit, 1),
        ]
        for c in cases {
            calls = []
            stagings = []
            let result = await install(installer(failing: c.failing))
            guard case .failure(let failure) = result else { XCTFail("\(c.failing) succeeded"); continue }
            XCTAssertEqual(failure.step, c.step, c.failing)
            XCTAssertEqual(calls.filter { $0 == "detach" }.count, c.detaches, c.failing)
            XCTAssertFalse(calls.contains("relaunch"), c.failing)
            XCTAssertEqual(version(installed), "0.5.0", c.failing)
            assertStagingRemoved()
        }
    }

    func testAStageFailureStillDetachesTheMount() async throws {
        try FileManager.default.removeItem(at: volume.appendingPathComponent("Parla.app")) // copy fails
        let result = await install(installer())
        guard case .failure(let failure) = result else { return XCTFail("succeeded") }
        XCTAssertEqual(failure.step, .stage)
        XCTAssertEqual(calls, ["download", "attach", "detach"])
        XCTAssertEqual(version(installed), "0.5.0")
        assertStagingRemoved()
    }

    func testAMountThatWontDetachKeepsItsStagingDir() async {
        // Removing it would walk into the still-mounted volume; both clear at reboot.
        let result = await install(installer(failing: "detach"))
        guard case .failure(let failure) = result else { return XCTFail("succeeded") }
        XCTAssertEqual(failure.step, .stage)
        XCTAssertEqual(calls, ["download", "attach", "detach", "detach"])
        XCTAssertTrue(stagings.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(version(installed), "0.5.0")
    }

    func testNoCommitBeforeSafeToRestart() async {
        let result = await install(installer(safeAfter: 2))
        XCTAssertEqual(try result.get(), .relaunching)
        XCTAssertEqual(Array(calls.drop { $0 != "claim" }), ["claim", "sleep", "claim", "sleep", "claim", "swap", "relaunch"])
    }

    func testDowngradeAndEqualVersionAreRejected() async {
        for candidate in ["0.5.0", "0.4.9"] {
            calls = []
            stagings = []
            makeApp(at: volume.appendingPathComponent("Parla.app"), version: candidate)
            let result = await install(installer())
            guard case .failure(let failure) = result else { XCTFail("\(candidate) installed"); continue }
            XCTAssertEqual(failure.step, .version, candidate)
            XCTAssertFalse(calls.contains("claim") || calls.contains("swap"), candidate)
            XCTAssertEqual(version(installed), "0.5.0")
            assertStagingRemoved()
        }
    }

    func testUnsupportedSwapFallsBackWithoutTouchingTheInstall() async {
        let result = await install(installer(swap: { _, _ in throw POSIXError(.ENOTSUP) }))
        guard case .failure(let failure) = result else { return XCTFail("succeeded") }
        XCTAssertEqual(failure.step, .commit)
        XCTAssertFalse(calls.contains("relaunch"))
        XCTAssertEqual(version(installed), "0.5.0")
        assertStagingRemoved()
    }

    func testRelaunchFailureIsReportedAsInstalled() async {
        let result = await install(installer(failing: "relaunch"))
        XCTAssertEqual(try result.get(), .reopenToFinish)
        XCTAssertEqual(version(installed), "0.6.0")
    }

    /// Quit before commit: the transaction is cancelled while it waits, cleans
    /// up, and never swaps.
    func testCancellationWhileWaitingCleansUpAndNeverSwaps() async {
        let waiting = installer(safeAfter: .max, sleep: { _ in try await Task.sleep(nanoseconds: 5_000_000) })
        let task = Task { await self.install(waiting) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        guard case .failure(let failure) = await task.value else { return XCTFail("succeeded") }
        XCTAssertEqual(failure.step, .commit)
        XCTAssertFalse(calls.contains("swap"))
        XCTAssertEqual(version(installed), "0.5.0")
        assertStagingRemoved()
    }

    /// Quit lands while verify runs; the restart is safe at once, so only the
    /// check before the swap stands between a cancelled install and a commit.
    func testCancellationDuringVerifyNeverSwaps() async {
        let cancelling = installer(onVerify: { withUnsafeCurrentTask { $0?.cancel() } })
        guard case .failure(let failure) = await install(cancelling) else { return XCTFail("succeeded") }
        XCTAssertEqual(failure.step, .commit)
        XCTAssertFalse(calls.contains("swap"))
        XCTAssertEqual(version(installed), "0.5.0")
        assertStagingRemoved()
    }

    func testAttachPlistGivesTheWholeDiskAndTheMountPoint() throws {
        let plist: NSDictionary = ["system-entities": [
            ["dev-entry": "/dev/disk7", "content-hint": "GUID_partition_scheme"],
            ["dev-entry": "/dev/disk7s1", "content-hint": "Apple_HFS", "mount-point": "/private/tmp/x/dmg.Ab12Cd"],
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        XCTAssertEqual(UpdateInstaller.mount(fromAttachPlist: data),
                       .init(device: "/dev/disk7", point: URL(fileURLWithPath: "/private/tmp/x/dmg.Ab12Cd")))
        XCTAssertNil(UpdateInstaller.mount(fromAttachPlist: Data("garbage".utf8)))
    }

    /// What make-dmg.sh's UDZO actually attaches as: APFS, two whole disks in
    /// varying order. Either whole disk ejects the image; a slice would not.
    func testAnAPFSAttachPlistGivesAWholeDisk() throws {
        let plist: NSDictionary = ["system-entities": [
            ["dev-entry": "/dev/disk12s1", "content-hint": "41504653-0000-11AA-AA11-00306543ECAC",
             "mount-point": "/private/tmp/x/dmg.Ef34Gh"],
            ["dev-entry": "/dev/disk11", "content-hint": "GUID_partition_scheme"],
            ["dev-entry": "/dev/disk11s1", "content-hint": "7C3457EF-0000-11AA-AA11-00306543ECAC"],
            ["dev-entry": "/dev/disk12", "content-hint": "EF57347C-0000-11AA-AA11-00306543ECAC"],
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let mount = try XCTUnwrap(UpdateInstaller.mount(fromAttachPlist: data))
        XCTAssertTrue(["/dev/disk11", "/dev/disk12"].contains(mount.device), mount.device)
        XCTAssertEqual(mount.point, URL(fileURLWithPath: "/private/tmp/x/dmg.Ef34Gh"))
    }

    // MARK: - Eligibility

    func testTranslocatedReadOnlyAndUnwritableLocationsAreRejected() throws {
        XCTAssertEqual(UpdateInstaller.locationProblem(
            URL(fileURLWithPath: "/private/var/folders/ab/T/AppTranslocation/1234/d/Parla.app")), .translocated)
        XCTAssertEqual(UpdateInstaller.locationProblem(URL(fileURLWithPath: "/usr/bin/Parla.app")), .readOnlyVolume)
        XCTAssertNil(UpdateInstaller.locationProblem(installed))
        let parent = installed.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
        XCTAssertEqual(UpdateInstaller.locationProblem(installed), .unwritableParent)
    }

    func testAnUnwritableBundleIsRejected() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: installed.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installed.path) }
        XCTAssertEqual(UpdateInstaller.locationProblem(installed), .unwritableBundle)
    }

    // MARK: - Signatures (throwaway ad-hoc bundles)

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) \(arguments)")
    }

    /// T.app with a nested, versioned Foo.framework, both ad-hoc signed inside-out.
    private func signedApp() throws -> (app: URL, framework: URL) {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/codesign") else {
            throw XCTSkip("codesign unavailable")
        }
        let app = root.appendingPathComponent("signed/T.app")
        let contents = app.appendingPathComponent("Contents")
        let framework = contents.appendingPathComponent("Frameworks/Foo.framework")
        let versionA = framework.appendingPathComponent("Versions/A")
        let fm = FileManager.default
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: versionA.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try fm.copyItem(atPath: "/usr/bin/true", toPath: contents.appendingPathComponent("MacOS/T").path)
        try fm.copyItem(atPath: "/usr/bin/true", toPath: versionA.appendingPathComponent("Foo").path)
        try fm.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try fm.createSymbolicLink(atPath: framework.appendingPathComponent("Foo").path, withDestinationPath: "Versions/Current/Foo")
        try fm.createSymbolicLink(atPath: framework.appendingPathComponent("Resources").path,
                                  withDestinationPath: "Versions/Current/Resources")
        let fooPlist: NSDictionary = ["CFBundleIdentifier": "test.parla.foo", "CFBundleExecutable": "Foo",
                                      "CFBundlePackageType": "FMWK"]
        XCTAssertTrue(fooPlist.write(to: versionA.appendingPathComponent("Resources/Info.plist"), atomically: true))
        let appPlist: NSDictionary = ["CFBundleIdentifier": "test.parla.app", "CFBundleExecutable": "T",
                                      "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.6.0"]
        XCTAssertTrue(appPlist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true))
        try run("/usr/bin/codesign", ["--force", "-s", "-", framework.path])
        try run("/usr/bin/codesign", ["--force", "-s", "-", "--identifier", "test.parla.app", app.path])
        return (app, framework)
    }

    func testAnAdHocIdentityIsNotATrustSource() throws {
        let (app, _) = try signedApp()
        XCTAssertThrowsError(try UpdateInstaller.trustedRequirement(of: UpdateInstaller.staticCode(app)))
    }

    func testAnAdHocCandidateIsRejected() throws {
        let (app, _) = try signedApp()
        // Positive control: the bundle itself is sound…
        XCTAssertNoThrow(try UpdateInstaller.verify(app: app, against: UpdateInstaller.requirement(#"identifier "test.parla.app""#)))
        // …but a Developer ID requirement (identifier + team) is not met by an ad-hoc signature.
        let developerID = try UpdateInstaller.requirement(
            #"identifier "test.parla.app" and anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345""#)
        XCTAssertThrowsError(try UpdateInstaller.verify(app: app, against: developerID))
    }

    func testATamperedNestedFrameworkIsRejected() throws {
        let (app, framework) = try signedApp()
        let requirement = try UpdateInstaller.requirement(#"identifier "test.parla.app""#)
        XCTAssertNoThrow(try UpdateInstaller.verify(app: app, against: requirement))
        // Only the framework's own seal covers this; the app's seal pins the
        // framework's code directory, which doesn't change — so this is caught
        // only by checking nested code.
        try Data("x".utf8).write(to: framework.appendingPathComponent("Versions/A/Resources/extra.txt"))
        XCTAssertThrowsError(try UpdateInstaller.verify(app: app, against: requirement))
    }
}
