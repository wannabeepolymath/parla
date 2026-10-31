import Darwin
import Foundation
import ParlaCore

protocol CatalogDownloadTransport {
    /// Returns only after the writer has exited, including on cancellation.
    func fetch(_ request: URLRequest, to file: URL, maximum: Int64, chunkMaximum: Int64) async throws -> HTTPURLResponse
}

/// A per-request serial delegate streams to disk. Cancellation waits for
/// didCompleteWithError; it never treats requesting cancellation as a drain.
struct CatalogURLSessionTransport: CatalogDownloadTransport {
    var configuration: () -> URLSessionConfiguration = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false; c.httpCookieStorage = nil; c.urlCredentialStorage = nil; c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 60; c.timeoutIntervalForResource = 3600
        return c
    }
    func fetch(_ request: URLRequest, to file: URL, maximum: Int64, chunkMaximum: Int64) async throws -> HTTPURLResponse {
        let transfer = Transfer(file: file, maximum: maximum, chunkMaximum: chunkMaximum)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                transfer.start(request, configuration: configuration(), continuation: continuation)
            }
        }, onCancel: { transfer.cancel() })
    }
    static func permitsRedirect(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host == "huggingface.co" || host.hasSuffix(".huggingface.co") || host.hasSuffix(".hf.co")
    }

    private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let file: URL, maximum: Int64, chunkMaximum: Int64
        let lock = NSLock()
        var task: URLSessionDataTask?, canceled = false
        var session: URLSession?
        var continuation: CheckedContinuation<HTTPURLResponse, Error>?
        var handle: FileHandle?, response: HTTPURLResponse?, failure: Error?
        var received: Int64 = 0, limit: Int64 = 0
        init(file: URL, maximum: Int64, chunkMaximum: Int64) {
            self.file = file; self.maximum = maximum; self.chunkMaximum = chunkMaximum
        }
        func start(_ request: URLRequest, configuration: URLSessionConfiguration,
                   continuation: CheckedContinuation<HTTPURLResponse, Error>) {
            lock.lock(); defer { lock.unlock() }
            guard !canceled else { continuation.resume(throwing: CancellationError()); return }
            let fd = open(file.path, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            var info = stat()
            guard fd >= 0, fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_nlink == 1, info.st_size == 0, info.st_mode & 0o077 == 0 else {
                if fd >= 0 { close(fd) }; continuation.resume(throwing: CatalogDownloadFailure()); return
            }
            handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            self.continuation = continuation
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            self.session = session
            let task = session.dataTask(with: request); self.task = task
            task.resume()
        }
        func cancel() {
            lock.lock(); canceled = true; let task = task; lock.unlock()
            task?.cancel()
        }
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            guard let url = request.url, CatalogURLSessionTransport.permitsRedirect(url) else {
                failure = CatalogDownloadFailure(); completionHandler(nil); task.cancel(); return
            }
            var clean = request
            clean.setValue(nil, forHTTPHeaderField: "Authorization")
            clean.setValue(nil, forHTTPHeaderField: "Cookie")
            clean.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            for header in ["Range", "If-Range"] {
                clean.setValue(task.originalRequest?.value(forHTTPHeaderField: header), forHTTPHeaderField: header)
            }
            completionHandler(clean)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse, let url = http.url, CatalogURLSessionTransport.permitsRedirect(url), [200, 206, 416].contains(http.statusCode) else {
                failure = CatalogDownloadFailure(); completionHandler(.cancel); return
            }
            self.response = http
            limit = http.statusCode == 206 ? chunkMaximum : (http.statusCode == 416 ? 0 : maximum)
            guard response.expectedContentLength <= limit else {
                failure = CatalogDownloadFailure(); completionHandler(.cancel); return
            }
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard failure == nil, Int64(data.count) <= limit - received else {
                failure = CatalogDownloadFailure(); dataTask.cancel(); return
            }
            do { try handle?.write(contentsOf: data); received += Int64(data.count) }
            catch { failure = CatalogDownloadFailure(); dataTask.cancel() }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            do { try handle?.synchronize(); try handle?.close() }
            catch { failure = CatalogDownloadFailure() }
            handle = nil
            lock.lock(); let canceled = canceled; self.task = nil; lock.unlock()
            let done = continuation; continuation = nil
            session.finishTasksAndInvalidate(); self.session = nil
            if canceled { done?.resume(throwing: CancellationError()) }
            else if let failure = failure ?? error { done?.resume(throwing: failure) }
            else if let response { done?.resume(returning: response) }
            else { done?.resume(throwing: CatalogDownloadFailure()) }
        }
    }
}
