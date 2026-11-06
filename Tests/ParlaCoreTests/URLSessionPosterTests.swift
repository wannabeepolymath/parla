import XCTest
@testable import ParlaCore

/// Answers https://origin.test with a 307 to https://elsewhere.test and records every host it is asked to load.
private final class RedirectingProtocol: URLProtocol {
    nonisolated(unsafe) static var hosts: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.hosts.append(url.host ?? "")
        if url.host == "origin.test" {
            let redirect = HTTPURLResponse(url: url, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": "https://elsewhere.test/v1/messages"])!
            var next = request; next.url = URL(string: "https://elsewhere.test/v1/messages")
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: redirect)
            client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
        } else {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class URLSessionPosterTests: XCTestCase {
    override func setUp() { RedirectingProtocol.hosts = []; URLProtocol.registerClass(RedirectingProtocol.self) }
    override func tearDown() { URLProtocol.unregisterClass(RedirectingProtocol.self) }

    func testCleanupTransportNeverFollowsARedirectToAnotherOrigin() async throws {
        var request = URLRequest(url: URL(string: "https://origin.test/v1/messages")!)
        request.httpMethod = "POST"; request.setValue("secret", forHTTPHeaderField: "x-api-key")
        request.httpBody = Data("transcript".utf8)
        let (_, response) = try await URLSessionPoster().post(request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 307)
        XCTAssertEqual(RedirectingProtocol.hosts, ["origin.test"])
    }
}
