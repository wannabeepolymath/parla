import XCTest
@testable import ParlaCore

final class LocalOCRCaptureTests: XCTestCase {
    private final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var cancellations = 0, releases = 0
        func cancel() { lock.withLock { cancellations += 1 } }
        func release() { lock.withLock { releases += 1 } }
        var cancelled: Int { lock.withLock { cancellations } }
        var released: Int { lock.withLock { releases } }
    }
    private final class ImageToken: @unchecked Sendable {
        let trace: Trace
        init(_ trace: Trace) { self.trace = trace }
        deinit { trace.release() }
    }
    @MainActor private final class World {
        var now = 10.0
        var state: LocalOCROwnedState? = LocalOCROwnedState(pid: 42, windowNumber: 7, generation: 1,
            frame: LocalOCRRect(x: 20, y: 30, width: 640, height: 384),
            primaryScreen: LocalOCRRect(x: 0, y: 0, width: 1920, height: 1080), scale: 2,
            primary: true, key: true, visible: true, active: true, plain: true, collapsed: true)
    }
    /// All OS bottoms are fail-on-entry spies unless a case explicitly admits
    /// that phase. Payloads are integers/headers/tokens, never real CGImages.
    @MainActor private final class Fake: LocalOCRDriver {
        enum Phase: Hashable { case preflight, lookup, filter, capture, vision }
        var allowed: Set<Phase> = []
        var supported = true, permission = true
        var counts: [Phase: Int] = [:]
        var holdMetadata = false, holdScreenshot = false, holdVision = false, holdPerform = false
        var windows: Result<[LocalOCRWindow<Int>], LocalOCRFailure>
        var filterResult: Result<LocalOCRFilter<Int>, LocalOCRFailure>
        var header = LocalOCRImageHeader(width: 1280, height: 768, bytesPerRow: 5120)
        var captureFailure: LocalOCRFailure?
        var words = ["amber cobalt willow"]
        var observationCount: Int?
        var performSuccess = true
        let trace = Trace()
        var image: ImageToken?
        var metadata: LocalOCRCallback<Result<[LocalOCRWindow<Int>], LocalOCRFailure>>?
        var screenshot: LocalOCRCallback<Result<LocalOCRImage<ImageToken>, LocalOCRFailure>>?
        var vision: LocalOCRCallback<Result<LocalOCRProjection, LocalOCRFailure>>?
        let metadataEntered = LocalOCRCallback<Bool>(), screenshotEntered = LocalOCRCallback<Bool>()
        let visionEntered = LocalOCRCallback<Bool>(), performReturn = LocalOCRCallback<Bool>()
        init(_ world: World) {
            let state = world.state!
            windows = .success([LocalOCRWindow(pid: 42, id: 7, frame: state.captureFrame, handle: 7)])
            filterResult = .success(LocalOCRFilter(handle: 7, rect: state.captureFrame, scale: 2))
        }
        private func entry(_ phase: Phase) {
            counts[phase, default: 0] += 1
            XCTAssertTrue(allowed.contains(phase), "forbidden native bottom entered")
        }
        func preflight() -> Bool { entry(.preflight); return permission }
        func lookup(_ callback: LocalOCRCallback<Result<[LocalOCRWindow<Int>], LocalOCRFailure>>) {
            entry(.lookup); metadata = callback
            if !holdMetadata { callback.receive { windows } }
            metadataEntered.receive { true }
        }
        func filter(_ window: Int) -> Result<LocalOCRFilter<Int>, LocalOCRFailure> {
            entry(.filter); XCTAssertEqual(window, 7); return filterResult
        }
        func capture(_ filter: Int, dimensions: LocalOCRDimensions,
                     callback: LocalOCRCallback<Result<LocalOCRImage<ImageToken>, LocalOCRFailure>>) {
            entry(.capture); XCTAssertEqual(filter, 7)
            XCTAssertEqual(dimensions.width, 1280); XCTAssertEqual(dimensions.height, 768)
            screenshot = callback
            if !holdScreenshot { deliverScreenshot() }
            screenshotEntered.receive { true }
        }
        func deliverMetadata(exit: Bool = true) {
            guard let metadata, metadata.begin() else { return }
            metadata.complete(windows)
            if exit { metadata.ownedBodyExited() }
        }
        func deliverScreenshot(exit: Bool = true) {
            guard let screenshot, screenshot.begin() else { return }
            if let captureFailure { screenshot.complete(.failure(captureFailure)) }
            else {
                let token = ImageToken(trace); image = token
                screenshot.complete(.success(LocalOCRImage(handle: token, header: header)))
            }
            if exit { screenshot.ownedBodyExited() }
        }
        func deliverVision(exit: Bool = true) {
            guard let vision, vision.begin() else { return }
            vision.complete(LocalOCRProjection.bounded(observationCount: observationCount ?? words.count) { i in
                i < words.count ? words[i] : nil
            })
            if exit { vision.ownedBodyExited() }
        }
        func returnPerform() { performReturn.receive { performSuccess } }
        private func startVision(_ callback: LocalOCRCallback<Result<LocalOCRProjection, LocalOCRFailure>>,
                                 operation: PendingOperation) -> LocalOCRCallback<Bool> {
            entry(.vision); vision = callback
            let trace = self.trace
            operation.installAbort { trace.cancel() }
            if !holdVision { deliverVision() }
            if !holdPerform { returnPerform() }
            visionEntered.receive { true }
            return performReturn
        }
        nonisolated func perform(_ image: ImageToken, operation: PendingOperation,
            callback: LocalOCRCallback<Result<LocalOCRProjection, LocalOCRFailure>>) async -> Bool {
            let returned = await startVision(callback, operation: operation)
            defer { withExtendedLifetime(image) {} }
            return await returned.wait()
        }
    }
    @MainActor private func rig() -> (World, Fake, LocalOCRCapture<Fake>) {
        let world = World()
        let fake = Fake(world)
        fake.allowed = [.preflight, .lookup, .filter, .capture, .vision]
        let capture = LocalOCRCapture(driver: fake, clock: { world.now }, state: { world.state })
        return (world, fake, capture)
    }
    private func projection(_ words: [String]) throws -> LocalOCRProjection {
        try LocalOCRProjection.bounded(observationCount: words.count) { words[$0] }.get()
    }
    private func failure(_ words: [String]) -> LocalOCRFailure? {
        switch LocalOCRProjection.bounded(observationCount: words.count, top: { words[$0] }) {
        case .success: return nil
        case .failure(let failure): return failure
        }
    }

    // P01/P08: shared parser, not a replica of executable dispatch.
    func testReservedInvocationGrammar() async {
        XCTAssertEqual(OwnedOCRInvocation.parse(["tool", "--owned-ocr-qualification"]), .owned)
        let bad = [
            ["--owned-ocr"], ["--OWNED-OCR-QUALIFICATION"], ["--owned-ocr-qualification=1"],
            ["--owned-ocr-qualificatio"], ["--owned-ocr-qualification", "--owned-ocr-qualification"],
            ["--owned-ocr-qualification", "com.apple.TextEdit"], ["--owned-ocr-qualification", "--paste"],
            ["--owned-ocr-qualification", "--echo-file", "/private/fixture"],
            ["--owned-ocr-qualification", "--field-role", "AXTextField"],
            ["--field-index", "1", "--owned-ocr-qualification"], ["--owned-ocr-qualification", "unknown"]
        ]
        for args in bad { XCTAssertEqual(OwnedOCRInvocation.parse(["tool"] + args), .refuse) }
        for args in [[], ["tool"], ["tool", "--paste"], ["tool", "--unknown"],
                     ["tool", "com.example.app"], ["tool", "--owned-oc"], ["tool", "--öwned-ocr"]] {
            XCTAssertEqual(OwnedOCRInvocation.parse(args), .legacy)
        }
        XCTAssertEqual(OwnedOCRInvocation.parse(["--owned-ocr"]), .refuse) // reserve ANY argv element
    }
    @MainActor func testMalformedGrammarHasZeroNewAndLegacyEntries() async {
        let (world, fake, capture) = rig(); fake.allowed = []
        var legacyEntries = 0, ownedEntries = 0
        for token in ["--owned-ocr", "--OWNED-OCR", "--owned-ocr-qualification=1"] {
            switch OwnedOCRInvocation.parse(["tool", token]) {
            case .legacy: legacyEntries += 1
            case .owned: ownedEntries += 1; capture.admitClick(); _ = await capture.run()
            case .refuse: break
            }
        }
        XCTAssertEqual(legacyEntries, 0); XCTAssertEqual(ownedEntries, 0); XCTAssertTrue(fake.counts.isEmpty)
        XCTAssertFalse(capture.admitted); XCTAssertEqual(world.now, 10)
    }
    @MainActor func testConstructorsNoClickAndUnsupportedHaveNoNativeEntries() async {
        _ = LocalOCRNativeDriver() // constructor only: no availability/permission/image query
        let (_, fake, capture) = rig(); fake.allowed = []
        let unclicked = await capture.run()
        XCTAssertEqual(unclicked.overall, .notTested); XCTAssertTrue(fake.counts.isEmpty)
        fake.supported = false; XCTAssertTrue(capture.admitClick())
        let unsupported = await capture.run()
        XCTAssertEqual(unsupported.reason, .unsupported); XCTAssertTrue(fake.counts.isEmpty)
        XCTAssertFalse(capture.pending); XCTAssertFalse(capture.admitClick())
    }
    @MainActor func testSingleClickStartsBudgetAndMissingPermissionHasZeroSC() async {
        let (world, fake, capture) = rig()
        fake.allowed = [.preflight]; fake.permission = false
        world.now = 900; XCTAssertTrue(capture.admitClick()); XCTAssertFalse(capture.admitClick())
        let receipt = await capture.run()
        XCTAssertEqual(receipt.reason, .permissionMissing); XCTAssertEqual(fake.counts, [.preflight: 1])
        XCTAssertTrue(receipt.operationExited); XCTAssertFalse(receipt.currentProcessMethodRequested)
        XCTAssertFalse(capture.admitClick()); _ = await capture.run(); XCTAssertEqual(fake.counts, [.preflight: 1])
    }
    @MainActor func testBudgetEqualityAndInvalidClockRefuseBeforePermission() async {
        for elapsed in [2.0, 2.00001, -1.0, Double.infinity, Double.nan] {
            let (world, fake, capture) = rig(); fake.allowed = []
            capture.admitClick(); world.now += elapsed
            let observed1 = await capture.run(); XCTAssertEqual(observed1.reason, .expired); XCTAssertTrue(fake.counts.isEmpty)
        }
        let (world, _, capture) = rig(); capture.admitClick(); world.now += 1.999
        let observed2 = await capture.run(); XCTAssertEqual(observed2.oracle, .pass)
    }
    // P02: direct fixture flags/identity, no AX security assertion.
    @MainActor func testInvalidOwnedProofHasZeroPermission() async {
        let mutations: [(inout LocalOCROwnedState) -> Void] = [
            { $0.pid = 0 }, { $0.windowNumber = 0 }, { $0.windowNumber = -1 },
            { $0.windowNumber = Int(UInt32.max) + 1 }, { $0.generation = 0 },
            { $0.key = false }, { $0.visible = false }, { $0.active = false },
            { $0.plain = false }, { $0.collapsed = false }, { $0.primary = false },
            { $0.frame.width = 641 }, { $0.frame.height = 385 }, { $0.frame.x = -1 },
            { $0.frame.y = 1000 }, { $0.primaryScreen.x = 1 }, { $0.scale = 2.01 },
            { $0.scale = 0 }, { $0.frame.width = .nan }
        ]
        for change in mutations {
            let (world, fake, capture) = rig(); fake.allowed = []
            change(&world.state!); capture.admitClick()
            let observed3 = await capture.run(); XCTAssertEqual(observed3.reason, .ownedState); XCTAssertTrue(fake.counts.isEmpty)
        }
        let (world, fake, capture) = rig(); world.state = nil; fake.allowed = []; capture.admitClick()
        let observed4 = await capture.run(); XCTAssertEqual(observed4.reason, .ownedState); XCTAssertTrue(fake.counts.isEmpty)
    }
    @MainActor func testLookupMissingForeignAmbiguousAndCapRefuse() async {
        let world = World(), good = LocalOCRWindow(pid: 42, id: 7, frame: World().state!.captureFrame, handle: 7)
        var wrongFrame = good.frame; wrongFrame.x += 1
        let arrays: [[LocalOCRWindow<Int>]] = [[], [good, good],
            [LocalOCRWindow(pid: nil, id: 7, frame: good.frame, handle: 7)],
            [LocalOCRWindow(pid: 43, id: 7, frame: good.frame, handle: 7)],
            [good, LocalOCRWindow(pid: 43, id: 8, frame: good.frame, handle: 8)],
            [LocalOCRWindow(pid: 42, id: 8, frame: good.frame, handle: 8)],
            [LocalOCRWindow(pid: 42, id: 7, frame: wrongFrame, handle: 7)],
            Array(repeating: good, count: 9)]
        XCTAssertTrue(world.state!.admissible)
        for windows in arrays {
            let (_, fake, capture) = rig(); fake.allowed = [.preflight, .lookup]; fake.windows = .success(windows)
            capture.admitClick(); let receipt = await capture.run()
            XCTAssertEqual(receipt.reason, windows.count > 8 ? .metadataLimit : .identityUnlinked)
            XCTAssertEqual(fake.counts, [.preflight: 1, .lookup: 1]); XCTAssertTrue(receipt.metadataOwnedBodyExited)
        }
    }
    @MainActor func testCoordinateRuleAndEightOwnWindowsPositive() async {
        let (_, fake, capture) = rig()
        let frame = World().state!.captureFrame
        XCTAssertEqual(frame.y, 666)
        var small = frame; small.x += 0.1
        XCTAssertTrue(LocalOCRDimensions.framesMatch(frame, small, scale: 2))
        small.x += 0.2; XCTAssertFalse(LocalOCRDimensions.framesMatch(frame, small, scale: 2))
        fake.windows = .success([LocalOCRWindow(pid: 42, id: 7, frame: frame, handle: 7)] +
            (8...14).map { LocalOCRWindow(pid: 42, id: UInt32($0), frame: frame, handle: $0) })
        capture.admitClick(); let observed5 = await capture.run(); XCTAssertEqual(observed5.oracle, .pass)
    }
    // P03: real observable headers only. No fake returned owner/window metadata.
    func testDimensionAndImageHeaderBounds() async {
        let rect = LocalOCRRect(x: 0, y: 0, width: 640, height: 384)
        let dims = LocalOCRDimensions.checked(rect: rect, scale: 2)!
        XCTAssertEqual(dims.width, 1280); XCTAssertEqual(dims.height, 768)
        XCTAssertEqual(dims.width * dims.height, 983040)
        for (width, height, scale) in [(0.0, 384.0, 2.0), (-1, 384, 2), (.infinity, 1, 1),
                                     (.nan, 1, 1), (768, 512, 2), (1536, 1024, 1),
                                     (1024, 1025, 1), (640, 384, 2.0001), (640, 384, 0)] {
            XCTAssertNil(LocalOCRDimensions.checked(rect: LocalOCRRect(x: 0, y: 0, width: width, height: height), scale: scale))
        }
        var header = LocalOCRImageHeader(width: 1280, height: 768, bytesPerRow: 5120)
        XCTAssertTrue(header.valid(for: dims))
        header.width += 1; XCTAssertFalse(header.valid(for: dims)); header.width -= 1
        header.height += 1; XCTAssertFalse(header.valid(for: dims)); header.height -= 1
        header.bytesPerRow = 5119; XCTAssertFalse(header.valid(for: dims))
        header.bytesPerRow = Int.max; XCTAssertFalse(header.valid(for: dims))
        header.bytesPerRow = -1; XCTAssertFalse(header.valid(for: dims))
        header.bytesPerRow = 5120; header.bitsPerPixel = 24; XCTAssertFalse(header.valid(for: dims))
        header.bitsPerPixel = 32; header.bitsPerComponent = 16; XCTAssertFalse(header.valid(for: dims))
        header.bitsPerComponent = 8; header.format = .unknown; XCTAssertFalse(header.valid(for: dims))
        let square = LocalOCRDimensions(width: 1024, height: 1024)
        header = LocalOCRImageHeader(width: 1024, height: 1024, bytesPerRow: 8192)
        XCTAssertTrue(header.valid(for: square)) // exactly 8MiB
        header.bytesPerRow += 1; XCTAssertFalse(header.valid(for: square))
    }
    @MainActor func testFilterCapsAndBadReturnedHeaderPreventVision() async {
        for scale in [0.0, 1.0, 2.001, Double.infinity] {
            let (_, fake, capture) = rig(); fake.allowed = [.preflight, .lookup, .filter]
            fake.filterResult = .success(LocalOCRFilter(handle: 7, rect: World().state!.captureFrame, scale: scale))
            capture.admitClick(); let observed6 = await capture.run(); XCTAssertEqual(observed6.reason, .dimensions)
            XCTAssertNil(fake.counts[.capture])
        }
        let (_, fake, capture) = rig(); fake.allowed = [.preflight, .lookup, .filter, .capture]
        fake.header.bytesPerRow = Int.max; capture.admitClick()
        let observed7 = await capture.run(); XCTAssertEqual(observed7.reason, .imageFormat); XCTAssertNil(fake.counts[.vision])
    }
    // P04: candidate bounds precede token expansion. Limits refuse, no trimming.
    func testObservationCandidateAndAggregateByteCaps() async throws {
        var accesses = 0
        let overflow = LocalOCRProjection.bounded(observationCount: 65) { _ in accesses += 1; return "amber" }
        XCTAssertThrowsError(try overflow.get()); XCTAssertEqual(accesses, 0)
        XCTAssertEqual(try LocalOCRProjection.bounded(observationCount: 64) { _ in "amber" }.get().observationCount, 64)
        XCTAssertEqual(failure([String(repeating: "a", count: 257)]), .candidateLimit)
        let candidate = String(repeating: "a ", count: 128) // exactly 256 bytes
        let exact = try projection(Array(repeating: candidate, count: 16))
        XCTAssertEqual(exact.candidateBytes, 4096); XCTAssertEqual(exact.terms, ["a"])
        XCTAssertEqual(failure(Array(repeating: candidate, count: 17)), .candidateLimit)
        XCTAssertEqual(try projection([]).terms.count, 0)
    }
    func testTermBoundsUnicodeNormalizationAndUnsafeContent() async throws {
        XCTAssertEqual(try projection(["AMBER amber", "e\u{301} É"]).terms, ["amber", "é"])
        XCTAssertEqual(try projection([String(repeating: "é", count: 32)]).terms.count, 1)
        XCTAssertEqual(failure([String(repeating: "a", count: 33)]), .termLimit)
        XCTAssertEqual(failure([String(repeating: "é", count: 33)]), .termLimit)
        XCTAssertEqual(failure(["a" + String(repeating: "\u{301}", count: 9)]), .termLimit)
        XCTAssertEqual(try projection(["中文 العربية café"]).terms.count, 3) // bounds, NOT language qualification
        for unsafe in ["a\nb", "a\rb", "a\tb", "a\0b", "a|b", "<system>", "[role]", "a:b", "a/b",
                       "a`b", "a\u{202e}b", "a\u{200d}b", "😀", "---"] {
            XCTAssertNotNil(failure([unsafe]))
        }
        let sixteen = (0..<16).map { "word\($0)" }
        XCTAssertEqual(try projection(sixteen).terms.count, 16)
        XCTAssertEqual(failure(sixteen + ["extra"]), .termLimit)
        let tail = (0..<15).map { String(repeating: "a", count: 30) + String(format: "%02d", $0) }
        XCTAssertEqual(try projection([String(repeating: "b", count: 17)] + tail).termBytes, 512)
        XCTAssertEqual(failure([String(repeating: "b", count: 18)] + tail), .termLimit)
    }
    func testStrictSentinelChromeAndDistinctWindowOracle() async throws {
        XCTAssertEqual(LocalOCRFixture.oracle(try projection(LocalOCRFixture.sentinels + LocalOCRFixture.chrome)).0, .pass)
        XCTAssertEqual(LocalOCRFixture.oracle(try projection(LocalOCRFixture.chrome)).0, .fail)
        let second = LocalOCRFixture.oracle(try projection(LocalOCRFixture.secondarySentinels + LocalOCRFixture.chrome))
        XCTAssertEqual(second.0, .fail); XCTAssertEqual(second.1, 3)
        let unexpected = LocalOCRFixture.oracle(try projection(LocalOCRFixture.sentinels + ["unspoken"]))
        XCTAssertEqual(unexpected.0, .fail); XCTAssertEqual(unexpected.1, 1)
    }
    // P05: held completion and owned exit are separate; every job joins both.
    @MainActor func testMetadataCompletionWithoutBodyExitRetainsLaneOnClose() async {
        let (_, fake, capture) = rig(); fake.holdMetadata = true; fake.allowed = [.preflight, .lookup]
        capture.admitClick(); let job = Task { await capture.run() }
        _ = await fake.metadataEntered.wait()
        fake.deliverMetadata(exit: false)
        XCTAssertTrue(fake.metadata!.didComplete); XCTAssertFalse(fake.metadata!.didExit)
        capture.revoke(); XCTAssertTrue(capture.pending); XCTAssertFalse(capture.operation!.hasExited)
        XCTAssertFalse(capture.admitClick()); XCTAssertNil(fake.counts[.capture])
        fake.metadata!.receive { .failure(.platform) } // duplicate cannot overwrite or resume
        XCTAssertFalse(fake.metadata!.didExit)
        fake.metadata!.ownedBodyExited()
        let receipt = await job.value
        XCTAssertEqual(receipt.reason, .revoked); XCTAssertTrue(receipt.metadataOwnedBodyExited)
        XCTAssertTrue(receipt.operationExited); XCTAssertNil(fake.counts[.capture])
    }
    @MainActor func testScreenshotLateCancelAndOwnedExitHoldImageUntilSettlement() async {
        let (_, fake, capture) = rig(); fake.holdScreenshot = true
        fake.allowed = [.preflight, .lookup, .filter, .capture]
        capture.admitClick(); let job = Task { await capture.run() }; _ = await fake.screenshotEntered.wait()
        fake.deliverScreenshot(exit: false); fake.image = nil
        XCTAssertEqual(fake.trace.released, 0)
        capture.revoke(); XCTAssertTrue(capture.pending); XCTAssertFalse(capture.admitClick())
        XCTAssertFalse(fake.screenshot!.didExit); XCTAssertNil(fake.counts[.vision])
        fake.screenshot!.ownedBodyExited()
        let receipt = await job.value
        XCTAssertEqual(receipt.reason, .revoked); XCTAssertTrue(receipt.screenshotOwnedBodyExited)
        XCTAssertEqual(fake.trace.released, 1); XCTAssertEqual(fake.trace.cancelled, 0)
        fake.screenshot!.receive { .failure(.platform) }; XCTAssertEqual(fake.counts[.capture], 1)
    }
    @MainActor func testVisionCancellationWaitsPerformReturnAndRetainsImage() async {
        let (_, fake, capture) = rig(); fake.holdPerform = true
        capture.admitClick(); let job = Task { await capture.run() }; _ = await fake.visionEntered.wait()
        fake.image = nil; capture.revoke()
        XCTAssertEqual(fake.trace.cancelled, 1); XCTAssertEqual(fake.trace.released, 0)
        XCTAssertTrue(fake.vision!.didExit); XCTAssertTrue(capture.pending); XCTAssertFalse(capture.admitClick())
        fake.returnPerform(); let receipt = await job.value
        XCTAssertEqual(receipt.reason, .revoked); XCTAssertTrue(receipt.visionPerformReturned)
        XCTAssertTrue(receipt.visionOwnedBodyExited); XCTAssertEqual(fake.trace.released, 1)
    }
    @MainActor func testVisionPerformReturnDoesNotReplaceOwnedCallbackExitOnQuit() async {
        let (_, fake, capture) = rig(); fake.holdVision = true
        capture.admitClick(); let job = Task { await capture.run() }; _ = await fake.visionEntered.wait()
        fake.deliverVision(exit: false); fake.image = nil; capture.revoke()
        XCTAssertTrue(fake.vision!.didComplete); XCTAssertFalse(fake.vision!.didExit)
        XCTAssertTrue(capture.pending); XCTAssertEqual(fake.trace.released, 0)
        fake.vision!.receive { .failure(.platform) }; XCTAssertFalse(fake.vision!.didExit)
        fake.vision!.ownedBodyExited(); let receipt = await job.value
        XCTAssertEqual(receipt.reason, .revoked); XCTAssertTrue(receipt.visionPerformReturned)
        XCTAssertTrue(receipt.visionOwnedBodyExited); XCTAssertEqual(fake.trace.released, 1)
        XCTAssertFalse(capture.admitClick())
    }
    @MainActor func testBudgetAndOwnedStateRecheckedAfterEveryAwait() async {
        for phase in 0...2 {
            let (world, fake, capture) = rig()
            fake.holdMetadata = phase == 0; fake.holdScreenshot = phase == 1; fake.holdPerform = phase == 2
            capture.admitClick(); let job = Task { await capture.run() }
            if phase == 0 { _ = await fake.metadataEntered.wait(); world.now += 2; fake.deliverMetadata() }
            if phase == 1 { _ = await fake.screenshotEntered.wait(); world.now += 2; fake.deliverScreenshot() }
            if phase == 2 { _ = await fake.visionEntered.wait(); world.now += 2; fake.returnPerform() }
            let receipt = await job.value; XCTAssertEqual(receipt.reason, .expired); XCTAssertNotEqual(receipt.oracle, .pass)
            if phase == 0 { XCTAssertNil(fake.counts[.capture]) }
            if phase == 1 { XCTAssertNil(fake.counts[.vision]) }
        }
        for phase in 0...2 {
            let (world, fake, capture) = rig()
            fake.holdMetadata = phase == 0; fake.holdScreenshot = phase == 1; fake.holdPerform = phase == 2
            capture.admitClick(); let job = Task { await capture.run() }
            if phase == 0 { _ = await fake.metadataEntered.wait(); world.state!.generation += 1; fake.deliverMetadata() }
            if phase == 1 { _ = await fake.screenshotEntered.wait(); world.state!.key = false; fake.deliverScreenshot() }
            if phase == 2 { _ = await fake.visionEntered.wait(); world.state!.scale = 1; fake.returnPerform() }
            let observed8 = await job.value; XCTAssertEqual(observed8.reason, .ownedState)
        }
    }
    @MainActor func testObservedAwayBackIsStickyAndNoSecondOperation() async {
        let (world, fake, capture) = rig(); fake.holdMetadata = true
        capture.admitClick(); let job = Task { await capture.run() }; _ = await fake.metadataEntered.wait()
        let original = world.state; world.state!.key = false; capture.revoke(); world.state = original
        fake.deliverMetadata(); let observed9 = await job.value; XCTAssertEqual(observed9.reason, .revoked)
        XCTAssertFalse(capture.admitClick()); _ = await capture.run(); XCTAssertEqual(fake.counts[.lookup], 1)
    }
    // P06/P07/P08: positive shipping composition + finite refusal receipts.
    @MainActor func testSuccessfulSharedAdapterOracleRemainsUnverified() async throws {
        let (_, fake, capture) = rig(); capture.admitClick(); let receipt = await capture.run()
        XCTAssertEqual(receipt.oracle, .pass); XCTAssertEqual(receipt.overall, .attemptedUnverified)
        XCTAssertEqual(fake.counts, [.preflight: 1, .lookup: 1, .filter: 1, .capture: 1, .vision: 1])
        XCTAssertTrue(receipt.metadataCompleted && receipt.metadataOwnedBodyExited)
        XCTAssertTrue(receipt.screenshotCompleted && receipt.screenshotOwnedBodyExited)
        XCTAssertTrue(receipt.visionCompleted && receipt.visionOwnedBodyExited && receipt.visionPerformReturned)
        XCTAssertTrue(receipt.operationExited); XCTAssertEqual(receipt.identityProof, "UNVERIFIED")
        XCTAssertEqual(receipt.metadataScope, "UNQUALIFIED"); XCTAssertFalse(receipt.imageHasOwnerMetadata)
        XCTAssertFalse(receipt.productQualified); XCTAssertEqual(receipt.revision, 3)
        XCTAssertEqual(receipt.language, "en-US"); XCTAssertEqual(receipt.recognitionLevel, "accurate")
        XCTAssertFalse(receipt.automaticallyDetectsLanguage || receipt.usesLanguageCorrection || receipt.includeChildWindows)
        XCTAssertTrue(receipt.ignoreShadowsSingleWindow); XCTAssertEqual(receipt.customWordsCount, 0)
        XCTAssertEqual(receipt.tccAttribution, "UNRECORDED"); XCTAssertEqual(receipt.binaryIdentity, "UNRECORDED")
        let encoded = try JSONEncoder().encode(receipt)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("amber"))
    }
    @MainActor func testFinitePlatformRefusalsAndNoReceiptContent() async throws {
        for phase in 0...2 {
            let (_, fake, capture) = rig()
            if phase == 0 { fake.windows = .failure(.platform); fake.allowed = [.preflight, .lookup] }
            if phase == 1 { fake.captureFailure = .platform; fake.allowed = [.preflight, .lookup, .filter, .capture] }
            if phase == 2 { fake.performSuccess = false }
            capture.admitClick(); let receipt = await capture.run()
            XCTAssertEqual(receipt.reason, .platform); XCTAssertTrue(receipt.operationExited)
        }
        for candidate in ["amber cobalt willow unspokenprivate", "/private/fixture-secret", "title\nsecret"] {
            let (_, fake, capture) = rig(); fake.words = [candidate]; capture.admitClick()
            let receipt = await capture.run(); XCTAssertEqual(receipt.overall, .fail)
            let line = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
            for forbidden in ["amber", "cobalt", "willow", "unspokenprivate", "/private/", "fixture-secret", "title", "secret"] {
                XCTAssertFalse(line.contains(forbidden))
            }
        }
    }
}
