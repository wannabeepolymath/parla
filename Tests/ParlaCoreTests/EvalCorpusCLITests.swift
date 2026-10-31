import XCTest
import Darwin
@testable import ParlaCore

/// Runs only the exact managed product emitted by the authorized root swift test.
/// There is no directory search, package/build invocation, model or audio decoder.
final class EvalCorpusCLITests: XCTestCase {
    private func executable() throws -> URL {
        guard let bundlePath = CommandLine.arguments.first(where: { $0.hasSuffix(".xctest") }) else {
            XCTFail("unsupported managed test product layout"); throw EvalCorpusError.unreadable
        }
        let test = URL(fileURLWithPath: bundlePath)
        let product = test.deletingLastPathComponent().appendingPathComponent("parla-eval")
        guard FileManager.default.isExecutableFile(atPath: product.path) else {
            XCTFail("required test-produced parla-eval unavailable"); throw EvalCorpusError.unreadable
        }
        print("CORPUS-CLI exact-managed-executable=\(product.path); version flag unavailable, source revision recorded by task")
        return product
    }
    private func probe(_ arguments: [String], fixture: EvalCorpusFixture) throws -> (Int32, String) {
        let p = Process(), output = Pipe(), error = Pipe()
        p.executableURL = try executable(); p.arguments = arguments
        p.currentDirectoryURL = fixture.root
        p.environment = [:]
        p.standardOutput = output; p.standardError = error
        try p.run()
        let pid = p.processIdentifier
        // Reports are bounded by tiny test-owned selections, below pipe capacity.
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = error.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        print("CORPUS-CLI parent=\(getpid()) child=\(pid) raw-exit=\(p.terminationStatus) reason=\(p.terminationReason.rawValue) absent=\(kill(pid, 0) == -1 && errno == ESRCH)")
        return (p.terminationStatus, String(decoding: out + err, as: UTF8.self))
    }
    func testProductionManifestSavedRunAndFailureExitZero() throws {
        let f = try EvalCorpusFixture()
        // Actual clock is used by CLI, so the test snapshot must already be effective.
        f.manifest["snapshotAt"] = .number("1700000000")
        f.mutateConsent { $0["effectiveAt"] = .number("1600000000"); $0["reviewedAt"] = .number("1700000000") }
        f.mutateCase { c in
            for key in ["verbatim", "cleaned"] {
                if case .object(var ref) = c[key] { ref["reviewedAt"] = .number("1700000000"); c[key] = .object(ref) }
            }
        }
        try f.writeManifest()
        let before = try FileManager.default.contentsOfDirectory(atPath: f.root.path).sorted()
        let metadata = try probe(["corpus-check", f.manifestPath], fixture: f)
        XCTAssertEqual(metadata.0, 0, metadata.1); XCTAssertTrue(metadata.1.contains("no model quality measured"))
        var run = try f.makeRun(hypothesis: "PRIVATE-CANARY")
        let path = try f.writeRun(run)
        let scored = try probe(["corpus-check", f.manifestPath, "--results", path], fixture: f)
        XCTAssertEqual(scored.0, 0, scored.1); XCTAssertTrue(scored.1.contains("quality-failed(>20%)=1/1"))
        XCTAssertFalse(scored.1.contains("PRIVATE-CANARY")); XCTAssertFalse(scored.1.contains(f.root.path))
        EvalCorpusFixture.mutateRow(&run) { $0["status"] = .string("failed"); $0["reason"] = .string("decode"); $0["hypothesis"] = .null }
        _ = try f.writeRun(run)
        let failed = try probe(["corpus-check", f.manifestPath, "--results", path], fixture: f)
        XCTAssertEqual(failed.0, 0, failed.1); XCTAssertTrue(failed.1.contains("scored=0 operational-failed=1"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.path).sorted(), (before + ["run.json"]).sorted())
    }
    func testActualStrictArgumentAndUnreadableRefusalsNoFallback() throws {
        let f = try EvalCorpusFixture(); try f.writeManifest()
        for args in [
            ["corpus-check"], ["corpus-check", f.manifestPath, "--out", "PRIVATE-CANARY"],
            ["verify", "corpus-check", f.manifestPath], ["--self-check", "corpus-check", f.manifestPath],
            ["corpus-check", f.manifestPath, "--results", "x.json", "--results", "y.json"],
            ["corpus-check", f.manifestPath, "--against", "x.json"],
            ["corpus-check", f.manifestPath, "extra"], ["corpus-check", f.manifestPath, "--unknown"],
            ["corpus-check", "PRIVATE-CANARY.json"],
            ["corpus-check", f.manifestPath, "--results", "--against"],
            ["corpus-check", f.manifestPath, "--cleanup-cmd", "PRIVATE-CANARY"]
        ] {
            let result = try probe(args, fixture: f)
            XCTAssertEqual(result.0, 2, result.1); XCTAssertFalse(result.1.contains("PRIVATE-CANARY")); XCTAssertFalse(result.1.contains(f.root.path))
            XCTAssertFalse(result.1.contains("No eval cases")); XCTAssertFalse(result.1.contains("model not found"))
        }
        try Data("{\"version\":1,\"version\":1}".utf8).write(to: URL(fileURLWithPath: f.manifestPath))
        XCTAssertEqual(try probe(["corpus-check", f.manifestPath], fixture: f).0, 2)
    }
}
