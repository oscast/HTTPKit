import Foundation

/// Per-backend request defaults. Validation occurs when RequestBuilder constructs a request.
public struct HTTPClientConfiguration: Sendable {
    public var baseURL: URL
    public var defaultHeaders: HTTPHeaders
    /// Finite positive timeout in seconds per attempt, not a deadline for the complete logical request.
    public var timeout: TimeInterval
    /// Opt in only for a controlled local development server. ATS still applies on iOS.
    public var allowsInsecureHTTP: Bool

    public init(
        baseURL: URL,
        defaultHeaders: HTTPHeaders = [:],
        timeout: TimeInterval = 30,
        allowsInsecureHTTP: Bool = false
    ) {
        self.baseURL = baseURL
        self.defaultHeaders = defaultHeaders
        self.timeout = timeout
        self.allowsInsecureHTTP = allowsInsecureHTTP
    }
}

public struct RequestBuilder: Sendable {
    public let configuration: HTTPClientConfiguration

    public init(configuration: HTTPClientConfiguration) { self.configuration = configuration }

    /// Builds a relative request with encoded path segments and validated, merged headers.
    /// Does not execute transport work or obtain authentication credentials.
    public func build<Response>(_ endpoint: Endpoint<Response>) throws -> URLRequest {
        guard var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil,
              configuration.timeout.isFinite, configuration.timeout > 0,
              scheme == "https" || scheme == "http" else {
            throw NetworkError.invalidConfiguration
        }
        guard scheme == "https" || configuration.allowsInsecureHTTP else {
            throw NetworkError.insecureConnection
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let segments = try endpoint.path.map { segment in
            guard !segment.isEmpty, segment != ".", segment != "..",
                  let encoded = segment.addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw NetworkError.invalidPath
            }
            return encoded
        }
        if !segments.isEmpty {
            let prefix = components.percentEncodedPath.hasSuffix("/")
                ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
            components.percentEncodedPath = prefix + "/" + segments.joined(separator: "/")
        }
        if !endpoint.query.isEmpty {
            components.queryItems = (components.queryItems ?? []) + endpoint.query
            // '+' is legal in a URL query but is interpreted as a space by many servers.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw NetworkError.invalidConfiguration }
        var headers = configuration.defaultHeaders.merging(endpoint.headers)
        if let contentType = endpoint.body?.contentType, headers["Content-Type"] == nil {
            headers["Content-Type"] = contentType
        }
        try Self.validate(headers)
        var request = URLRequest(url: url, timeoutInterval: configuration.timeout)
        request.httpMethod = endpoint.method.rawValue
        request.httpBody = endpoint.body?.data
        request.allHTTPHeaderFields = headers.fields
        return request
    }

    static func validate(_ headers: HTTPHeaders) throws {
        let token = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~")
        for (name, value) in headers.fields {
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ token.contains($0) }),
                  value.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 || $0.value == 9 }) else {
                throw NetworkError.invalidHeader
            }
        }
    }
}
