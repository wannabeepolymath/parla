import Foundation

/// Immutable prepared lease supplied only by G2, plus an independently expected
/// product identity from G3. Default factory services refuse before native IO.
public final class ParakeetInstallationLease {
    public let directory: URL
    public let product: ParakeetProductIdentity
    public let osScope: String
    public let scope: ParakeetPreparedScope?
    private let current: () -> Bool
    public var isCurrent: Bool { current() }
    private let release: () -> Void
    public init(directory: URL, product: ParakeetProductIdentity, osScope: String,
                scope: ParakeetPreparedScope? = nil, isCurrent: @escaping () -> Bool = { true }, release: @escaping () -> Void) {
        self.directory = directory; self.product = product; self.osScope = osScope; self.release = release
        self.scope = scope; current = isCurrent
    }
    deinit { release() }
}
public final class ParakeetRecognition: RecognitionClient {
    public var capabilities: RecognitionCapabilities { .parakeet }
    private let admission = NSLock()
    private var revoked = false
    public var deliveryRevoked: Bool { !lease.isCurrent || admission.withLock { revoked } }
    public let wireIdentity: ParakeetWire.Identity
    private let lease: ParakeetInstallationLease
    private let product: ParakeetTrustedProduct
    private let worker: ParakeetWorker
    private let filter: String?
    private var used = false
    init(lease: ParakeetInstallationLease, product: ParakeetTrustedProduct, filter: String?, worker: ParakeetWorker) throws {
        self.lease = lease; self.product = product; self.filter = filter; self.worker = worker
        wireIdentity = .init(helperBuild: product.identity.helperSHA256, osScope: lease.osScope)
        try wireIdentity.validate()
        guard lease.product == product.identity, filter.map({ ParakeetWire.filters.contains($0) }) ?? true else { throw ParakeetRefusal.configuration }
    }
    public func recognize(_ samples: [Float], initialPrompt: String?, language: String?, shouldAbort: (() -> Bool)?) async -> RecognitionNativeOutcome {
        guard lease.isCurrent else { admission.withLock { revoked = true }; return .canceled }
        guard initialPrompt == nil, admission.withLock({
            if used { return false }
            used = true; return true
        }) else { return .failed(.unsupportedCapability) } // one physical worker per immutable session
        let request = ParakeetWire.Record(identity: wireIdentity, mode: .recognizeBatch, directory: lease.directory.path,
            sampleCount: samples.count, filter: filter)
        let result = await worker.run(product: product, request: request, samples: samples,
            shouldAbort: { [lease] in !lease.isCurrent || shouldAbort?() == true })
        admission.withLock { revoked = result.deliveryRevoked || !lease.isCurrent }
        guard !result.expired else { return .failed(.deadline) }
        guard let terminal = result.terminal else { return .failed(.parakeet) }
        switch terminal.code {
        case .completed: return .completed(.init(text: terminal.text ?? ""))
        case .canceled: return .canceled
        case .failed, nil: return .failed(.parakeet)
        }
    }
    public func transcribe(_ samples: [Float], initialPrompt: String?, language: String?, shouldAbort: (() -> Bool)?) async -> String? {
        await recognize(samples, initialPrompt: initialPrompt, language: language, shouldAbort: shouldAbort).text
    }
}
