import Foundation

public protocol HTTPTransport: Sendable {
    /// Executes without filtering HTTP status codes; the client applies endpoint validation.
    /// Implementations must cooperate with task cancellation and protect shared mutable state.
    func execute(_ request: URLRequest) async throws -> HTTPResponse
}

/// Retains an injected session without changing its cookies/cache/delegates or invalidating it.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    private let redirects = SameOriginRedirectDelegate()

    public init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    public func execute(_ request: URLRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request, delegate: redirects)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw NetworkError.invalidResponse }
        var headers = HTTPHeaders()
        for (name, value) in http.allHeaderFields {
            if let name = name as? String { headers[name] = String(describing: value) }
        }
        return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data, url: http.url)
    }
}

// Reject cross-origin and HTTPS-downgrade redirects rather than risk forwarding credentials.
// No mutable state; Foundation invokes this delegate on its own queue.
final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url, let target = request.url,
              target.user == nil, target.password == nil else {
            completionHandler(nil)
            return
        }
        completionHandler(Self.sameOrigin(original, target) ? request : nil)
    }

    private static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
        func port(_ url: URL) -> Int? { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return first.scheme?.lowercased() == second.scheme?.lowercased()
            && first.host?.lowercased() == second.host?.lowercased() && port(first) == port(second)
    }
}
