import XCTest
@testable import ParlaCore

private final class CallbackHandle: HistoryRetryHTTPHandle {
    let start: () -> Void, stop: () -> Void
    init(start: @escaping () -> Void, stop: @escaping () -> Void) { self.start = start; self.stop = stop }
    func resume() { start() }
    func cancel() { stop() }
}
final class HistoryRetryHTTPTests: XCTestCase {
    private func request(_ count: Int = 2) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://example.test/private")!); r.httpMethod = "POST"; r.httpBody = Data(repeating: 42, count: count); return r
    }
    func testRealAccumulatorAcceptsMultipleCallbacksBeforeReturningData() async throws {
        let policy = HistoryRetryExecutionPolicy(planned: 1)
        let http = HistoryRetryHTTP(policy: policy) { request, callbacks in
            CallbackHandle(start: {
                XCTAssertTrue(callbacks.response(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!))
                XCTAssertTrue(callbacks.data(Data("one".utf8))); XCTAssertTrue(callbacks.data(Data("two".utf8)))
                callbacks.completed(nil); callbacks.exited()
                XCTAssertFalse(callbacks.data(Data("late".utf8)))
            }, stop: {})
        }
        let (data, _) = try await http.post(request()); XCTAssertEqual(String(decoding: data, as: UTF8.self), "onetwo")
        XCTAssertEqual(policy.finish().attempted, 1)
    }
    func testHeadersBodyRedirectAndRequestCapsAtCallbacks() async {
        for kind in 0...3 {
            let policy = HistoryRetryExecutionPolicy(planned: 1)
            let http = HistoryRetryHTTP(policy: policy) { r, c in
                CallbackHandle(start: {
                    if kind == 0 {
                        XCTAssertFalse(c.response(HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: ["Huge": String(repeating: "x", count: 16 * 1024)])!))
                    } else {
                        XCTAssertTrue(c.response(HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
                        if kind == 1 {
                            XCTAssertTrue(c.data(Data(repeating: 1, count: 256 * 1024)))
                            XCTAssertFalse(c.data(Data([2])))
                        } else { c.redirect() }
                    }
                    c.completed(nil); c.exited()
                }, stop: {})
            }
            do { _ = try await http.post(request(kind == 3 ? 128 * 1024 + 1 : 2)); XCTFail("Must refuse") } catch {}
        }
    }
    func testCompletionDoesNotReleaseUntilActualExit() async throws {
        let entered = expectation(description: "complete but not exited")
        let finished = expectation(description: "returned only after exit")
        let lock = NSLock(); var callbacks: HistoryRetryHTTPCallbacks?
        let http = HistoryRetryHTTP(policy: HistoryRetryExecutionPolicy(planned: 1)) { r, c in
            lock.withLock { callbacks = c }
            return CallbackHandle(start: {
                _ = c.response(HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                _ = c.data(Data([1])); c.completed(nil); entered.fulfill()
            }, stop: {})
        }
        let task = Task { defer { finished.fulfill() }; return try await http.post(request()) }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertFalse(lock.withLock { callbacks == nil })
        task.cancel() // cancellation still cannot release the transfer
        lock.withLock { callbacks }?.exited()
        do { _ = try await task.value; XCTFail("Canceled") } catch {}
        await fulfillment(of: [finished], timeout: 2)
    }
}

extension HistoryRetryHTTPTests {
    func testCancellationBeforeHandleInstallDoesNotSendAndStillWaitsExit() async throws {
        let gate = DispatchSemaphore(value: 0), entered = expectation(description: "driver before install")
        let canceled = expectation(description: "installed handle canceled")
        let lock = NSLock(); var callbacks: HistoryRetryHTTPCallbacks?, resumed = 0
        let policy = HistoryRetryExecutionPolicy(planned: 1)
        let http = HistoryRetryHTTP(policy: policy) { _, c in
            lock.withLock { callbacks = c }; entered.fulfill(); gate.wait()
            return CallbackHandle(start: { lock.withLock { resumed += 1 } }, stop: { c.completed(CancellationError()); canceled.fulfill() })
        }
        let running = Task { try await http.post(self.request()) }
        await fulfillment(of: [entered], timeout: 2)
        running.cancel(); gate.signal()
        await fulfillment(of: [canceled], timeout: 2)
        XCTAssertEqual(lock.withLock { resumed }, 0); XCTAssertEqual(policy.finish().attempted, 0)
        lock.withLock { callbacks }?.exited()
        do { _ = try await running.value; XCTFail("Canceled") } catch {}
    }
}


extension HistoryRetryHTTPTests {
    func testB21ConstructionResumeRevocationCancelsSuspendedHandleAndJoins() async throws {
        for boundary in [0,1,2] {
            var checks = 0, constructs = 0, resumes = 0, cancels = 0
            let admission = CleanupFailoverHTTPAdmission(enter:{ action in
                checks += 1
                if boundary == checks {throw CleanupFailoverFailure.revoked}
                try action()
            },subscribe:{_ in {}},started:{})
            let http = HistoryRetryHTTP(policy:HistoryRetryExecutionPolicy(planned:1),driver:{r,c in
                constructs += 1
                return CallbackHandle(start:{
                    resumes += 1;_=c.response(HTTPURLResponse(url:r.url!,statusCode:200,httpVersion:nil,headerFields:nil)!);_=c.data(Data([1]));c.exited();c.completed(nil)
                },stop:{cancels += 1;c.completed(CancellationError());c.exited()})
            },failoverAdmission:admission)
            do {_ = try await http.post(request());XCTAssertEqual(boundary,0)}catch{XCTAssertNotEqual(boundary,0)}
            XCTAssertEqual(constructs,boundary == 1 ? 0 : 1);XCTAssertEqual(resumes,boundary == 0 ? 1 : 0);XCTAssertEqual(cancels,boundary == 2 ? 2 : 0)
        }
    }
    func testB21ExplicitRequestHeaderAndBodyExactCaps() async throws {
        for extra in [0,1] {
            var calls = 0
            let admission = CleanupFailoverHTTPAdmission(enter:{try $0()},subscribe:{_ in {}},started:{})
            let http = HistoryRetryHTTP(policy:HistoryRetryExecutionPolicy(planned:1),driver:{r,c in
                calls += 1;return CallbackHandle(start:{_=c.response(HTTPURLResponse(url:r.url!,statusCode:200,httpVersion:nil,headerFields:nil)!);_=c.data(Data([1]));c.completed(nil);c.exited()},stop:{})
            },failoverAdmission:admission)
            var r = request(128*1024);r.setValue(String(repeating:"x",count:16*1024-17+extra),forHTTPHeaderField:"Authorization")
            do {_ = try await http.post(r);XCTAssertEqual(extra,0)}catch{XCTAssertEqual(extra,1)}
            XCTAssertEqual(calls,extra == 0 ? 1 : 0)
        }
    }
}


extension HistoryRetryHTTPTests {
    func testB21ResponseHeaderBodyAndRequestExactPlusOneCapsBothCallbackOrders() async throws {
        for kind in 0..<3 {
            for extra in [0,1] {
                var canceled=0
                let http=HistoryRetryHTTP(policy:HistoryRetryExecutionPolicy(planned:1)){r,c in
                    CallbackHandle(start:{
                        let header=kind == 0 ? ["X":String(repeating:"h",count:16*1024-5+extra)]:[:]
                        let accepted=c.response(HTTPURLResponse(url:r.url!,statusCode:200,httpVersion:nil,headerFields:header)!)
                        if accepted {_=c.data(Data(repeating:1,count:kind == 1 ? 256*1024+extra:1))}
                        c.exited();c.completed(nil)
                    },stop:{canceled += 1})
                }
                do {_=try await http.post(request(kind == 2 ? 128*1024+extra:1));XCTAssertEqual(extra,0)}catch{XCTAssertEqual(extra,1)}
                if extra == 1 && kind < 2 {XCTAssertGreaterThan(canceled,0)}
            }
        }
    }
    func testB21ExitWithoutCompletionRetainsContinuationUntilCanceledCompletion() async throws {
        let entered=expectation(description:"exited but not completed"),lock=NSLock();var c:HistoryRetryHTTPCallbacks?,returned=false
        let http=HistoryRetryHTTP(policy:HistoryRetryExecutionPolicy(planned:1)){_,callbacks in
            lock.withLock{c=callbacks};return CallbackHandle(start:{callbacks.exited();entered.fulfill()},stop:{})
        }
        let task=Task{defer{lock.withLock{returned=true}};return try await http.post(request())}
        await fulfillment(of:[entered],timeout:3);XCTAssertFalse(lock.withLock{returned});task.cancel()
        XCTAssertFalse(lock.withLock{returned});lock.withLock{c}?.completed(CancellationError())
        do{_=try await task.value;XCTFail("Canceled")}catch{}
        XCTAssertTrue(lock.withLock{returned})
    }
}
