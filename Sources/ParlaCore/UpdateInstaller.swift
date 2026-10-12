import Foundation
import Security

/// One update transaction: download the release DMG, mount it, copy Parla.app
/// out, verify its signature and version, wait until nothing is in flight,
/// then swap it over the installed app in one atomic rename and relaunch.
/// Every step before the swap is non-destructive, and every failure before it
/// cleans up after itself. The side effects are injected so the order and the
/// cleanup are testable without a network, a mount or a signed app; `live`
/// wires the real ones.
public struct UpdateInstaller {
    public enum Step: String, Sendable { case download, mount, stage, verify, version, commit }

    /// A failure before the swap: the installed app is untouched.
    public struct Failure: Error, Equatable {
        public let step: Step
        public let reason: String
    }

    /// The swap happened. `.reopenToFinish` = the relaunch couldn't be spawned.
    public enum Installed: Equatable, Sendable { case relaunching, reopenToFinish }

    public struct Mount: Equatable, Sendable {
        public let device: String
        public let point: URL
    }

    struct Message: Error, CustomStringConvertible { let description: String }

    var download: (_ from: URL, _ to: URL) async throws -> Void
    var attach: (_ dmg: URL, _ under: URL) async throws -> Mount
    var detach: (_ device: String) async throws -> Void
    var verify: (_ app: URL) throws -> Void
    var swap: (_ staged: URL, _ installed: URL) throws -> Void
    var relaunch: (_ app: URL) throws -> Void
    /// On the main actor, in one turn: if nothing is in flight, refuse new
    /// dictations from here on and say true. Polled until it does.
    var claimRestart: () async -> Bool
    var sleep: (TimeInterval) async throws -> Void
    var stagingDirectory: (_ appropriateFor: URL) throws -> URL

    /// Runs the whole transaction. Throws `Failure` for anything before the
    /// swap, including cancellation (a Quit before commit). Once
    /// `claimRestart` has said true, cancellation is no longer checked.
    public func install(dmg: URL, currentVersion: String, at installed: URL) async throws -> Installed {
        let staging: URL
        do { staging = try stagingDirectory(installed) }
        catch { throw Failure(step: .download, reason: "\(error)") }
        let app = staging.appendingPathComponent("Parla.app")
        var step = Step.download
        var mount: Mount?
        do {
            let file = staging.appendingPathComponent("Parla.dmg")
            try await download(dmg, file)
            try Task.checkCancellation()
            step = .mount
            let attached = try await attach(file, staging)
            mount = attached
            step = .stage
            try FileManager.default.copyItem(at: attached.point.appendingPathComponent("Parla.app"), to: app)
            try await detach(attached.device)
            mount = nil
            try Task.checkCancellation()
            step = .verify
            try verify(app)
            step = .version
            let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
            guard let version = plist?["CFBundleShortVersionString"] as? String,
                  UpdateCheck.isNewer(remote: version, current: currentVersion) else {
                throw Message(description: "not newer than \(currentVersion)")
            }
            step = .commit
            while !(await claimRestart()) { try await sleep(0.2) }
            try Task.checkCancellation() // a Quit during verify must not still commit
            try swap(app, installed)
        } catch {
            let failure = Failure(step: step, reason: "\(error)")
            // ponytail: a mount that won't detach keeps its staging dir (it lives
            // inside); both clear at reboot — no leftover recovery until seen.
            if let mount, (try? await detach(mount.device)) == nil { throw failure }
            try? FileManager.default.removeItem(at: staging)
            throw failure
        }
        try? FileManager.default.removeItem(at: staging) // the old app now; harmless if it stays
        do { try relaunch(installed) } catch { return .reopenToFinish }
        return .relaunching
    }
}

// MARK: - Eligibility

extension UpdateInstaller {
    public enum Ineligible: Equatable, Sendable { case translocated, readOnlyVolume, unwritableParent, unwritableBundle }

    /// Advisory, checked before Install is offered: each step still handles
    /// its own failure.
    public static func locationProblem(_ app: URL) -> Ineligible? {
        if app.path.contains("/AppTranslocation/") { return .translocated }
        let parent = app.deletingLastPathComponent().path
        var fs = statfs()
        // statfs, not .volumeIsReadOnlyKey: that says false for the sealed system volume.
        if statfs(parent, &fs) == 0, fs.f_flags & UInt32(MNT_RDONLY) != 0 { return .readOnlyVolume }
        if !FileManager.default.isWritableFile(atPath: parent) { return .unwritableParent }
        // A cross-directory swap also needs write access to the bundle itself
        // (another account's or a sudo-installed copy fails EACCES at commit).
        if !FileManager.default.isWritableFile(atPath: app.path) { return .unwritableBundle }
        return nil
    }
}

// MARK: - Signatures

extension UpdateInstaller {
    /// The Developer ID CA intermediate and a Developer ID Application leaf.
    static let developerID = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    private static func check(_ status: OSStatus, _ call: String) throws {
        guard status == errSecSuccess else { throw Message(description: "\(call) failed (\(status))") }
    }

    static func requirement(_ text: String) throws -> SecRequirement {
        var requirement: SecRequirement?
        try check(SecRequirementCreateWithString(text as CFString, [], &requirement), "SecRequirementCreateWithString")
        guard let requirement else { throw Message(description: "no requirement") }
        return requirement
    }

    static func staticCode(_ app: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        try check(SecStaticCodeCreateWithPath(app as CFURL, [], &code), "SecStaticCodeCreateWithPath")
        guard let code else { throw Message(description: "no static code") }
        return code
    }

    /// The trust source for every candidate: the running app's designated
    /// requirement (identifier + team), only once the running app proved it is
    /// Developer ID-signed. Local ad-hoc builds (make-app.sh's identifier-only
    /// DR) and `swift run` throw here and get the browser fallback.
    public static func runningRequirement() throws -> SecRequirement {
        var me: SecCode?
        try check(SecCodeCopySelf([], &me), "SecCodeCopySelf")
        guard let me else { throw Message(description: "no running code") }
        try check(SecCodeCheckValidity(me, [], try requirement(developerID)), "SecCodeCheckValidity")
        var onDisk: SecStaticCode?
        try check(SecCodeCopyStaticCode(me, [], &onDisk), "SecCodeCopyStaticCode")
        guard let onDisk else { throw Message(description: "no static code") }
        return try trustedRequirement(of: onDisk)
    }

    /// The on-disk half of `runningRequirement` — the part a test can drive,
    /// since it can't change how its own process is signed.
    static func trustedRequirement(of code: SecStaticCode) throws -> SecRequirement {
        try check(SecStaticCodeCheckValidity(code, [], try requirement(developerID)), "SecStaticCodeCheckValidity")
        var designated: SecRequirement?
        try check(SecCodeCopyDesignatedRequirement(code, [], &designated), "SecCodeCopyDesignatedRequirement")
        guard let designated else { throw Message(description: "no designated requirement") }
        return designated
    }

    /// The staged candidate, nested code and every architecture included.
    public static func verify(app: URL, against requirement: SecRequirement) throws {
        let flags = SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        try check(SecStaticCodeCheckValidity(try staticCode(app), flags, requirement), "SecStaticCodeCheckValidity")
    }
}

// MARK: - Live side effects

extension UpdateInstaller {
    /// `progress` gets raw fractions off the main thread; `claimRestart` is the app's.
    public static func live(requirement: SecRequirement,
                            progress: @escaping (Double) -> Void,
                            claimRestart: @escaping () async -> Bool) -> UpdateInstaller {
        UpdateInstaller(
            download: { try await download($0, to: $1, progress: progress) },
            attach: { dmg, dir in
                let plist = try await hdiutil(["attach", "-nobrowse", "-readonly", "-plist",
                                               "-mountrandom", dir.path, dmg.path])
                // ponytail: an attach with no mount point in its plist is left attached
                // (no device to trust); a valid release DMG always has one.
                guard let mount = mount(fromAttachPlist: plist) else { throw Message(description: "no mount point") }
                return mount
            },
            detach: { _ = try await hdiutil(["detach", $0]) },
            verify: { try verify(app: $0, against: requirement) },
            swap: exchange,
            relaunch: { try relaunch(app: $0, after: getpid()) },
            claimRestart: claimRestart,
            sleep: { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
            stagingDirectory: {
                try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                            appropriateFor: $0, create: true)
            })
    }

    /// One atomic exchange: the new app lands at `installed`, the old one at
    /// `staged`. Any failure, ENOTSUP/EXDEV included, leaves both untouched.
    static func exchange(_ staged: URL, _ installed: URL) throws {
        guard renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, installed.path, UInt32(RENAME_SWAP)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Hands the task to `didCreateTask` so its own Progress can be observed —
    /// ModelInstaller's KVO pattern, with the async API's cancellation.
    private final class ProgressDelegate: NSObject, URLSessionTaskDelegate {
        let report: (Double) -> Void
        var observation: NSKeyValueObservation?
        init(_ report: @escaping (Double) -> Void) { self.report = report }
        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            observation = task.progress.observe(\.fractionCompleted) { [report] p, _ in report(p.fractionCompleted) }
        }
    }

    static func download(_ url: URL, to file: URL, progress: @escaping (Double) -> Void) async throws {
        let delegate = ProgressDelegate(progress)
        defer { delegate.observation?.invalidate() }
        let (tmp, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Message(description: "HTTP \(http.statusCode)")
        }
        try FileManager.default.moveItem(at: tmp, to: file)
    }

    /// The subset of `hdiutil attach -plist` we read.
    struct AttachPlist: Decodable {
        let entities: [Entity]
        enum CodingKeys: String, CodingKey { case entities = "system-entities" }
        struct Entity: Decodable {
            let device: String
            let mountPoint: String?
            enum CodingKeys: String, CodingKey { case device = "dev-entry", mountPoint = "mount-point" }
        }
    }

    /// A whole disk (/dev/diskN) is the shortest dev-entry; detaching it takes
    /// its slices with it. An APFS image has two whole disks (the GUID disk and
    /// its synthesized container) — detaching either ejects the whole image.
    static func mount(fromAttachPlist data: Data) -> Mount? {
        guard let entities = try? PropertyListDecoder().decode(AttachPlist.self, from: data).entities,
              let point = entities.lazy.compactMap(\.mountPoint).first,
              let device = entities.map(\.device).min(by: { $0.count < $1.count }) else { return nil }
        return Mount(device: device, point: URL(fileURLWithPath: point))
    }

    /// stdin closed (a license prompt fails instead of hanging), bounded by a
    /// timeout, and awaited to exit — a Quit waits for it rather than orphaning it.
    static func hdiutil(_ arguments: [String], timeout: TimeInterval = 120) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { p in
                // ponytail: read at exit — attach's plist is a few KB, well under the
                // pipe buffer; output past it would stall until the timeout kills it.
                let data = out.fileHandleForReading.readDataToEndOfFile()
                if p.terminationReason == .exit, p.terminationStatus == 0 {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: Message(description: "hdiutil \(arguments[0]) failed (\(p.terminationStatus))"))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }
    }

    /// Polls for `$1` (this process) to exit, every 0.2 s for at most 30 s, then
    /// opens `$2`; on timeout it exits without launching. PID and path are
    /// arguments, never spliced into the script.
    static let relaunchScript = #"i=0; while /bin/kill -0 "$1" 2>/dev/null; do i=$((i+1)); [ "$i" -ge 150 ] && exit 1; /bin/sleep 0.2; done; /usr/bin/open "$2""#

    static func relaunch(app: URL, after pid: pid_t) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", relaunchScript, "sh", String(pid), app.path]
        try process.run()
    }
}
