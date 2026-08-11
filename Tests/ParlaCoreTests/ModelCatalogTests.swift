import XCTest
@testable import ParlaCore

final class ModelCatalogTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parla-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A catalog entry with the hash of `bytes`, so install/verify can be
    /// exercised without a 574 MB fixture.
    private func fixture(_ bytes: Data, id: String = "base.en") -> ModelCatalog.Model {
        ModelCatalog.Model(id: id, displayName: "Fixture",
                           bytes: Int64(bytes.count),
                           sha256: ModelCatalogTests.sha256(bytes))
    }

    private static func sha256(_ data: Data) -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try! data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try! ModelCatalog.sha256(ofFileAt: url)
    }

    private func write(_ data: Data, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: - Catalog

    func testCatalogIdsAreUniqueAndWellFormed() {
        XCTAssertEqual(Set(ModelCatalog.all.map(\.id)).count, ModelCatalog.all.count)
        for m in ModelCatalog.all {
            XCTAssertEqual(m.filename, "ggml-\(m.id).bin")
            XCTAssertEqual(m.url.lastPathComponent, m.filename)
            XCTAssertEqual(m.sha256.count, 64, m.id)
            XCTAssertGreaterThan(m.bytes, 0, m.id)
        }
    }

    func testDefaultIsBaseEnSoExistingInstallsKeepWorking() {
        XCTAssertEqual(ModelCatalog.default.id, "base.en")
        XCTAssertEqual(ModelCatalog.path(for: ModelCatalog.default),
                       ModelCatalog.directory.appendingPathComponent("ggml-base.en.bin").path)
    }

    func testModelLookupByPathIgnoresDirectory() {
        XCTAssertEqual(ModelCatalog.model(atPath: "/anywhere/ggml-base.en.bin")?.id, "base.en")
        XCTAssertNil(ModelCatalog.model(atPath: "/anywhere/my-own-model.bin"))
    }

    // MARK: - Markup sniffing (vibe #353)

    func testMarkupSniffCatchesProxyErrorPages() {
        XCTAssertTrue(ModelCatalog.looksLikeMarkup(Data("<!DOCTYPE html><html>…".utf8)))
        XCTAssertTrue(ModelCatalog.looksLikeMarkup(Data("\n  <html><body>Sign in".utf8)))
        XCTAssertTrue(ModelCatalog.looksLikeMarkup(Data("<?xml version=\"1.0\"?><Error/>".utf8)))
        // ggml's own magic, and arbitrary binary, must never trip it.
        XCTAssertFalse(ModelCatalog.looksLikeMarkup(Data("ggml".utf8)))
        XCTAssertFalse(ModelCatalog.looksLikeMarkup(Data([0x67, 0x67, 0x6d, 0x6c, 0xff, 0x00, 0x3c])))
        XCTAssertFalse(ModelCatalog.looksLikeMarkup(Data()))
    }

    // MARK: - Verification

    func testVerifyAcceptsExactBytes() throws {
        let data = Data("a plausible model payload".utf8)
        let url = try write(data, "good.bin")
        XCTAssertNoThrow(try ModelCatalog.verify(fileAt: url, is: fixture(data)))
    }

    func testVerifyRejectsWrongLengthWithBothNumbers() throws {
        let url = try write(Data("short".utf8), "short.bin")
        let model = fixture(Data("a much longer payload".utf8))
        XCTAssertThrowsError(try ModelCatalog.verify(fileAt: url, is: model)) { error in
            let text = (error as? ModelFileError)?.description ?? ""
            XCTAssertTrue(text.contains("\(model.bytes)"), text)
            XCTAssertTrue(text.contains("got 5"), text)
        }
    }

    func testVerifyRejectsAnHTMLPageOfTheRightLength() throws {
        let page = Data("<html>Sign in to your proxy</html>".utf8)
        let url = try write(page, "page.bin")
        // Same length as the pinned model, different bytes: the markup check is
        // what turns "hash mismatch" into a diagnosable error.
        let model = ModelCatalog.Model(id: "base.en", displayName: "Fixture",
                                       bytes: Int64(page.count), sha256: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try ModelCatalog.verify(fileAt: url, is: model)) { error in
            XCTAssertTrue(((error as? ModelFileError)?.description ?? "").contains("web page"))
        }
    }

    func testVerifyRejectsWrongHash() throws {
        let data = Data("the wrong revision of the model".utf8)
        let url = try write(data, "wrong.bin")
        let model = ModelCatalog.Model(id: "base.en", displayName: "Fixture",
                                       bytes: Int64(data.count), sha256: String(repeating: "a", count: 64))
        XCTAssertThrowsError(try ModelCatalog.verify(fileAt: url, is: model)) { error in
            XCTAssertTrue(((error as? ModelFileError)?.description ?? "").contains("sha256"))
        }
    }

    // MARK: - Install (vibe PR #1245)

    func testInstallReplacesTheExistingModel() throws {
        let dest = dir.appendingPathComponent("ggml-base.en.bin")
        try Data("old model".utf8).write(to: dest)
        let new = Data("new model".utf8)
        let staged = try write(new, "staged.part")

        try ModelCatalog.install(staged: staged, as: fixture(new), at: dest,
                                 cache: VerifiedCache(url: dir.appendingPathComponent("v.json")))

        XCTAssertEqual(try Data(contentsOf: dest), new)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path + ".backup"))
    }

    /// The bug this whole path exists to kill: Parla used to remove the existing
    /// model before the move, so a bad download left the user with nothing.
    func testFailedVerificationLeavesTheOldModelInPlace() throws {
        let dest = dir.appendingPathComponent("ggml-base.en.bin")
        try Data("old model".utf8).write(to: dest)
        let staged = try write(Data("<html>proxy</html>".utf8), "staged.part")
        let model = fixture(Data("a completely different payload".utf8))

        XCTAssertThrowsError(try ModelCatalog.install(staged: staged, as: model, at: dest,
                                                      cache: VerifiedCache(url: dir.appendingPathComponent("v.json"))))
        XCTAssertEqual(try Data(contentsOf: dest), Data("old model".utf8))
    }

    func testInstallClearsAStaleBackupFromAnEarlierCrash() throws {
        let dest = dir.appendingPathComponent("ggml-base.en.bin")
        try Data("old model".utf8).write(to: dest)
        try Data("crash leftover".utf8).write(to: dest.appendingPathExtension("backup"))
        let new = Data("new model".utf8)
        let staged = try write(new, "staged.part")

        try ModelCatalog.install(staged: staged, as: fixture(new), at: dest,
                                 cache: VerifiedCache(url: dir.appendingPathComponent("v.json")))
        XCTAssertEqual(try Data(contentsOf: dest), new)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path + ".backup"))
    }

    // MARK: - Hash cache (ghost-pepper #163)

    func testCacheRemembersAVerifiedFileAndForgetsARewriteOfTheSameLength() throws {
        let cache = VerifiedCache(url: dir.appendingPathComponent("v.json"))
        let file = try write(Data("model".utf8), "ggml-base.en.bin")

        XCTAssertFalse(cache.isVerified(file))
        cache.record(file)
        XCTAssertTrue(cache.isVerified(file))

        // Same path, different bytes, *same length* — the only case that proves
        // mtime is part of the identity (macparakeet's disk-identity rule: a
        // stale verdict must not bless a re-download). A rewrite that also
        // changed the size would still be caught by a size-only identity, so it
        // would test nothing. mtime is stamped rather than left to the clock:
        // two writes microseconds apart can round to the same Date.
        try Data("MODEL".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: file.path)
        XCTAssertFalse(cache.isVerified(file))
    }

    func testCacheIgnoresAMissingFile() {
        let cache = VerifiedCache(url: dir.appendingPathComponent("v.json"))
        let gone = dir.appendingPathComponent("gone.bin")
        cache.record(gone)
        XCTAssertFalse(cache.isVerified(gone))
    }

    /// A model the user pointed at themselves is never hashed — nothing is
    /// pinned for it, and it's the escape hatch if HuggingFace re-uploads one
    /// of ours (pindrop #785).
    func testUserSuppliedModelOutsideTheModelsDirectoryIsNotVerified() throws {
        let file = try write(Data("<html>not even a model</html>".utf8), "ggml-base.en.bin")
        XCTAssertNil(ModelCatalog.verifyInstalled(path: file.path,
                                                  cache: VerifiedCache(url: dir.appendingPathComponent("v.json"))))
    }
}
