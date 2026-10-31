import Foundation

/// The only injectable network bottom. Production installs a suspended task;
/// callbacks and actual session invalidation, not Data-return checks, drain it.
public protocol HistoryRetryHTTPHandle: AnyObject {
    func resume()
    func cancel()
}
public struct HistoryRetryHTTPCallbacks {
    public let response: (HTTPURLResponse) -> Bool
    public let data: (Data) -> Bool
    public let redirect: () -> Void
    public let completed: (Error?) -> Void
    public let exited: () -> Void
}
public struct HistoryRetryHTTP: HTTPPosting {
    public typealias Driver = (URLRequest, HistoryRetryHTTPCallbacks) -> HistoryRetryHTTPHandle
    private let policy: HistoryRetryExecutionPolicy
    private let driver: Driver
    private let failoverAdmission: CleanupFailoverHTTPAdmission?
    public init(policy: HistoryRetryExecutionPolicy, driver: @escaping Driver = HistoryRetryURLSession.init,
                failoverAdmission: CleanupFailoverHTTPAdmission? = nil) {
        self.policy = policy; self.driver = driver; self.failoverAdmission = failoverAdmission
    }
    public func post(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try policy.check()
        guard request.httpMethod == "POST", let body = request.httpBody, body.count <= 128 * 1024 else { throw SegmentedRetryFailure.request }
        if failoverAdmission != nil {
            let headers = (request.allHTTPHeaderFields ?? [:]).reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count + 4 }
            guard headers <= 16 * 1024 else { throw SegmentedRetryFailure.headers }
        }
        var bounded = request
        bounded.timeoutInterval = min(request.timeoutInterval, try policy.remaining())
        let transfer = HistoryRetryHTTPTransfer(policy: policy)
        let unsubscribe = try failoverAdmission?.subscribe { transfer.cancel() }
        defer { unsubscribe?() }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                transfer.start(bounded, driver: driver, admission: failoverAdmission, continuation: continuation)
            }
        }, onCancel: { transfer.cancel() })
    }
}

private final class HistoryRetryHTTPTransfer: @unchecked Sendable {
    let policy: HistoryRetryExecutionPolicy
    let lock = NSLock()
    var handle: HistoryRetryHTTPHandle?
    var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    var response: HTTPURLResponse?, failure: Error?
    var body = Data(), receivedHeaders = 0
    var canceled = false, complete = false, exit = false, settled = false
    init(policy: HistoryRetryExecutionPolicy) { self.policy = policy }
    func start(_ request: URLRequest, driver: @escaping HistoryRetryHTTP.Driver, admission: CleanupFailoverHTTPAdmission?,
               continuation: CheckedContinuation<(Data, URLResponse), Error>) {
        lock.withLock { self.continuation = continuation }
        let callbacks = HistoryRetryHTTPCallbacks(response: { [self] in receive($0) }, data: { [self] in receive($0) },
            redirect: { [self] in fail(SegmentedRetryFailure.response) },
            completed: { [self] error in lock.withLock { complete = true; if failure == nil { failure = error } }; settle() },
            exited: { [self] in lock.withLock { exit = true }; settle() })
        let handle: HistoryRetryHTTPHandle
        do {
            var constructed: HistoryRetryHTTPHandle?
            let construct = {
                try self.policy.check()
                guard !self.lock.withLock({ self.canceled }) else { throw SegmentedRetryFailure.canceled }
                constructed = driver(request, callbacks)
            }
            if let admission { try admission.enter(construct) } else { constructed = driver(request, callbacks) }
            handle = constructed!
        } catch {
            lock.withLock { failure = error; complete = true; exit = true }; settle(); return
        }
        let cancel = lock.withLock { self.handle = handle; return canceled || failure != nil || settled }
        if cancel { handle.cancel(); return }
        do {
            let resume = { try self.policy.attempt(); admission?.started(); handle.resume() }
            if let admission { try admission.enter(resume) } else { try resume() }
        }
        catch { fail(error); handle.cancel() }
    }
    func cancel() {
        let handle = lock.withLock { canceled = true; return self.handle }
        handle?.cancel()
    }
    func fail(_ error: Error) {
        let handle = lock.withLock { if failure == nil { failure = error }; return self.handle }
        handle?.cancel()
    }
    func receive(_ response: HTTPURLResponse) -> Bool {
        do {
            try policy.check()
            return try lock.withLock {
                guard !settled, !complete, !canceled, failure == nil, self.response == nil else { return false }
                // Count before retaining a response; keys/values already belong to
                // Foundation, whose pre-callback allocations are outside this cap.
                for (key, value) in response.allHeaderFields {
                    let cost = String(describing: key).utf8.count + String(describing: value).utf8.count + 4
                    guard cost <= 16 * 1024 - receivedHeaders else { throw SegmentedRetryFailure.headers }
                    receivedHeaders += cost
                }
                guard response.expectedContentLength <= 256 * 1024 else { throw SegmentedRetryFailure.response }
                self.response = response; return true
            }
        } catch { fail(error); return false }
    }
    func receive(_ data: Data) -> Bool {
        do {
            try policy.check()
            return try lock.withLock {
                guard !settled, !complete, !canceled, failure == nil, response != nil else { return false }
                guard data.count <= 256 * 1024 - body.count else { throw SegmentedRetryFailure.response }
                try policy.reserve(data.count)
                body.append(data); return true
            }
        } catch { fail(error); return false }
    }
    func settle() {
        let result: (CheckedContinuation<(Data, URLResponse), Error>, Result<(Data, URLResponse), Error>)? = lock.withLock {
            guard complete, exit, !settled, let continuation else { return nil }
            settled = true; self.continuation = nil; handle = nil
            let retained = body.count
            defer { policy.release(retained); body = Data() }
            if canceled { return (continuation, .failure(SegmentedRetryFailure.canceled)) }
            if let failure { return (continuation, .failure(failure)) }
            guard let response else { return (continuation, .failure(SegmentedRetryFailure.response)) }
            return (continuation, .success((body, response)))
        }
        if let (continuation, result) = result { continuation.resume(with: result) }
    }
}

/// Serial callbacks and separate didBecomeInvalid acknowledgement retain both
/// session and task until actual exit. No cache/cookies/ambient client credentials.
public final class HistoryRetryURLSession: NSObject, HistoryRetryHTTPHandle, URLSessionDataDelegate, @unchecked Sendable {
    private let callbacks: HistoryRetryHTTPCallbacks
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    public init(_ request: URLRequest, _ callbacks: HistoryRetryHTTPCallbacks) {
        self.callbacks = callbacks
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = request.timeoutInterval
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session; task = session.dataTask(with: request)
    }
    public func resume() { lock.withLock { task }?.resume() }
    public func cancel() { lock.withLock { task }?.cancel() }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        callbacks.redirect(); completionHandler(nil); task.cancel()
    }
    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Server trust follows platform validation. Never reuse ambient client
        // credentials or retry a challenged authenticated POST.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        self.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        completionHandler(callbacks.response(response) ? .allow : .cancel)
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if !callbacks.data(data) { dataTask.cancel() }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        callbacks.completed(error); session.finishTasksAndInvalidate()
    }
    public func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        lock.withLock { task = nil; self.session = nil }; callbacks.exited()
    }
}
