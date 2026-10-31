import Foundation

public enum HTTPMethod: String, Sendable, CaseIterable {
    case get = "GET", head = "HEAD", post = "POST", put = "PUT"
    case patch = "PATCH", delete = "DELETE", options = "OPTIONS"

    public var isIdempotent: Bool {
        switch self {
        case .get, .head, .put, .delete, .options: true
        case .post, .patch: false
        }
    }
}

/// Case-insensitive HTTP field names. Repeated response fields are combined by Foundation.
public struct HTTPHeaders: Sendable, Equatable, ExpressibleByDictionaryLiteral {
    public private(set) var fields: [String: String]

    public init(_ fields: [String: String] = [:]) {
        self.fields = [:]
        for (name, value) in fields { self[name] = value }
    }

    public init(dictionaryLiteral elements: (String, String)...) {
        fields = [:]
        for (name, value) in elements { self[name] = value }
    }

    public subscript(_ name: String) -> String? {
        get { fields[name.lowercased()] }
        set { fields[name.lowercased()] = newValue }
    }

    public func merging(_ other: HTTPHeaders) -> HTTPHeaders {
        HTTPHeaders(fields.merging(other.fields) { _, new in new })
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: HTTPHeaders
    public let body: Data
    public let url: URL?

    public init(statusCode: Int, headers: HTTPHeaders = [:], body: Data = Data(), url: URL? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.url = url
    }
}

public struct HTTPBody: Sendable {
    public let data: Data
    public let contentType: String?

    public init(data: Data, contentType: String? = nil) {
        self.data = data
        self.contentType = contentType
    }

    public static func json<Value: Encodable>(
        _ value: Value,
        configure: (JSONEncoder) -> Void = { _ in }
    ) throws -> HTTPBody {
        let encoder = JSONEncoder()
        configure(encoder)
        return try HTTPBody(data: encoder.encode(value), contentType: "application/json")
    }
}

public struct EmptyResponse: Sendable, Equatable {
    public init() {}
}

/// Creates a fresh decoder for each call; no mutable JSONDecoder is shared between tasks.
public struct ResponseDecoder<Value: Sendable>: Sendable {
    private let decodeValue: @Sendable (HTTPResponse) throws -> Value

    public init(_ decode: @escaping @Sendable (HTTPResponse) throws -> Value) {
        decodeValue = decode
    }

    public func decode(_ response: HTTPResponse) throws -> Value {
        try decodeValue(response)
    }
}

extension ResponseDecoder where Value: Decodable {
    public static func json(
        configure: @escaping @Sendable (JSONDecoder) -> Void = { _ in }
    ) -> Self {
        Self { response in
            let decoder = JSONDecoder()
            configure(decoder)
            return try decoder.decode(Value.self, from: response.body)
        }
    }
}

extension ResponseDecoder where Value == Data {
    public static var data: Self { Self { $0.body } }
}

extension ResponseDecoder where Value == EmptyResponse {
    /// Explicitly ignores the body. Use for HEAD, DELETE or 204 contracts, not JSON endpoints.
    public static var empty: Self { Self { _ in EmptyResponse() } }
}

public enum ReplayPolicy: Sendable {
    case never
    case idempotentMethods
    /// The caller guarantees replay is safe (for example, a server-enforced idempotency key).
    case allowed

    func permits(_ method: HTTPMethod) -> Bool {
        switch self {
        case .never: false
        case .idempotentMethods: method.isIdempotent
        case .allowed: true
        }
    }
}

/// A relative route. Every path element is encoded as one segment, including embedded slashes.
public struct Endpoint<Response: Sendable>: Sendable {
    public var path: [String]
    public var method: HTTPMethod
    public var query: [URLQueryItem]
    public var headers: HTTPHeaders
    public var body: HTTPBody?
    public var requiresAuthentication: Bool
    public var replayPolicy: ReplayPolicy
    public var acceptedStatusCodes: Range<Int>
    public var decoder: ResponseDecoder<Response>

    public init(
        path: [String] = [],
        method: HTTPMethod = .get,
        query: [URLQueryItem] = [],
        headers: HTTPHeaders = [:],
        body: HTTPBody? = nil,
        requiresAuthentication: Bool = false,
        replayPolicy: ReplayPolicy = .idempotentMethods,
        acceptedStatusCodes: Range<Int> = 200..<300,
        decoder: ResponseDecoder<Response>
    ) {
        self.path = path
        self.method = method
        self.query = query
        self.headers = headers
        self.body = body
        self.requiresAuthentication = requiresAuthentication
        self.replayPolicy = replayPolicy
        self.acceptedStatusCodes = acceptedStatusCodes
        self.decoder = decoder
    }
}

extension Endpoint where Response: Decodable {
    public static func json(
        path: [String] = [],
        method: HTTPMethod = .get,
        query: [URLQueryItem] = [],
        headers: HTTPHeaders = [:],
        body: HTTPBody? = nil,
        requiresAuthentication: Bool = false,
        replayPolicy: ReplayPolicy = .idempotentMethods,
        configureDecoder: @escaping @Sendable (JSONDecoder) -> Void = { _ in }
    ) -> Self {
        Self(path: path, method: method, query: query, headers: headers, body: body,
             requiresAuthentication: requiresAuthentication, replayPolicy: replayPolicy,
             decoder: .json(configure: configureDecoder))
    }
}

public struct DecodedResponse<Value: Sendable>: Sendable {
    public let value: Value
    public let response: HTTPResponse
}
