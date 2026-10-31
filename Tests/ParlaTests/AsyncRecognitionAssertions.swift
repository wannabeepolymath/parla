import XCTest

// XCTest's synchronous autoclosures cannot contain an awaited recognition call.
func recognitionAssertEqual<T: Equatable>(_ value: T, _ expected: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(value, expected, message, file: file, line: line)
}
func recognitionAssertNil<T>(_ value: T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertNil(value, message, file: file, line: line)
}
func recognitionAssertNotNil<T>(_ value: T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertNotNil(value, message, file: file, line: line)
}
func recognitionUnwrap<T>(_ value: T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, message, file: file, line: line)
}
func recognitionAssertThrows<T>(_ value: @autoclosure () async throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line, _ handler: (Error) -> Void = { _ in }) async {
    do { _ = try await value(); XCTFail("Expected error. " + message, file: file, line: line) }
    catch { handler(error) }
}

/// Test latch with semaphore ordering and actual suspension, never a blocking bridge.
final class RecognitionTestLatch {
    private let lock = NSLock()
    private var permits = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if permits > 0 { permits -= 1; return true }
                waiters.append(continuation); return false
            }
            if ready { continuation.resume() }
        }
    }
    func signal() {
        let pending: CheckedContinuation<Void, Never>? = lock.withLock {
            if !waiters.isEmpty { return waiters.removeFirst() }
            permits += 1; return nil
        }
        pending?.resume()
    }
}
