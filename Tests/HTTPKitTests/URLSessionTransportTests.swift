import Foundation
import Testing
@testable import HTTPKit

@Suite("URLSession adapter")
struct URLSessionTransportTests {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixedURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test func executesRealSessionAndPreservesHTTPFields() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: try #require(URL(string: "https://example.com/success")))
        request.httpMethod = "PATCH"
        let response = try await URLSessionTransport(session: session).execute(request)
        #expect(response.statusCode == 202)
        #expect(response.headers["X-Method"] == "PATCH")
        #expect(response.body == Data([0, 1, 255]))
        #expect(response.url == request.url)
    }

    @Test func exposesURLSessionTransportFailure() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: try #require(URL(string: "https://example.com/failure")))
        do {
            _ = try await URLSessionTransport(session: session).execute(request)
            Issue.record("Expected URL error")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        }
    }

    @Test func rejectsNonHTTPResponse() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: try #require(URL(string: "https://example.com/non-http")))
        await #expect(throws: NetworkError.self) { try await URLSessionTransport(session: session).execute(request) }
    }

    @Test func preCancelledTaskDoesNotStartSession() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: try #require(URL(string: "https://example.com/success")))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await URLSessionTransport(session: session).execute(request)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test(arguments: [
        ("https://example.com/next", true),
        ("https://EXAMPLE.com:443/next", true),
        ("https://other.example.com/next", false),
        ("http://example.com/next", false),
        ("https://example.com:8443/next", false),
        ("https://user:password@example.com/next", false)
    ])
    func redirectPolicy(_ value: (String, Bool)) async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let original = try #require(URL(string: "https://example.com/start"))
        let task = session.dataTask(with: original)
        defer { task.cancel() }
        let redirect = URLRequest(url: try #require(URL(string: value.0)))
        let response = try #require(HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil))
        await confirmation("Redirect completion is called once") { completed in
            SameOriginRedirectDelegate().urlSession(session, task: task, willPerformHTTPRedirection: response,
                newRequest: redirect) { request in
                    #expect((request != nil) == value.1)
                    completed()
                }
        }
    }
}

// Foundation's URLProtocol inherits unchecked sendability. This fixture adds no mutable state;
// all behavior is fixed per request and no static handler/registry is shared across parallel tests.
private final class FixedURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.path == "/failure" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let response: URLResponse
        if url.path == "/non-http" {
            response = URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        } else {
            guard let http = HTTPURLResponse(url: url, statusCode: 202, httpVersion: "HTTP/1.1",
                headerFields: ["X-Method": request.httpMethod ?? "missing"]) else { return }
            response = http
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([0, 1, 255]))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
