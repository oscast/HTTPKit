import Foundation
import Testing
@testable import HTTPKit

@Suite("Request construction")
struct RequestBuilderTests {
    private func builder(_ url: String = "https://api.example.com/v1/", headers: HTTPHeaders = [:]) throws -> RequestBuilder {
        RequestBuilder(configuration: .init(baseURL: try #require(URL(string: url)), defaultHeaders: headers))
    }

    @Test func encodesSegmentsAndRepeatedQueries() throws {
        let endpoint = Endpoint<Data>(path: ["users", "a/b ?+#é"], query: [
            URLQueryItem(name: "tag", value: "a+b &c"), URLQueryItem(name: "tag", value: "two"),
            URLQueryItem(name: "flag", value: nil)
        ], decoder: .data)
        let request = try builder().build(endpoint)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.percentEncodedPath == "/v1/users/a%2Fb%20%3F%2B%23%C3%A9")
        #expect(components.queryItems == endpoint.query)
        #expect(components.percentEncodedQuery?.contains("%2B") == true)
        #expect(request.httpMethod == "GET")
    }

    @Test func preservesBaseQueryAndTimeout() throws {
        let configuration = HTTPClientConfiguration(baseURL: try #require(URL(string: "https://example.com/v1?key=one")), timeout: 12)
        let request = try RequestBuilder(configuration: configuration).build(Endpoint<Data>(
            query: [.init(name: "key", value: "two")], decoder: .data))
        #expect(URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems == [
            .init(name: "key", value: "one"), .init(name: "key", value: "two")
        ])
        #expect(request.timeoutInterval == 12)
    }

    @Test func mergesHeadersCaseInsensitivelyAndEncodesBody() throws {
        struct Payload: Encodable { let firstName: String }
        let body = try HTTPBody.json(Payload(firstName: "Ana")) { $0.keyEncodingStrategy = .convertToSnakeCase }
        let request = try builder(headers: ["ACCEPT": "application/json", "X-Env": "old"]).build(
            Endpoint<Data>(method: .post, headers: ["x-env": "new"], body: body, decoder: .data))
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-Env") == "new")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: String] == ["first_name": "Ana"])
    }

    @Test(arguments: ["", ".", ".."]) func rejectsAmbiguousPath(_ path: String) throws {
        #expect(throws: NetworkError.self) { try builder().build(Endpoint<Data>(path: [path], decoder: .data)) }
    }

    @Test(arguments: ["file:///tmp/test", "https://user:password@example.com", "https://example.com/#fragment", "ftp://example.com"])
    func rejectsInvalidBase(_ url: String) throws {
        #expect(throws: NetworkError.self) { try builder(url).build(Endpoint<Data>(decoder: .data)) }
    }

    @Test func requiresExplicitHTTPOptIn() throws {
        let url = try #require(URL(string: "http://localhost:8080"))
        let endpoint = Endpoint<Data>(decoder: .data)
        #expect(throws: NetworkError.self) { try RequestBuilder(configuration: .init(baseURL: url)).build(endpoint) }
        let request = try RequestBuilder(configuration: .init(baseURL: url, allowsInsecureHTTP: true)).build(endpoint)
        #expect(request.url == url)
    }

    @Test(arguments: [HTTPHeaders(["Bad\nName": "value"]), ["X-Test": "value\r\nInjected: yes"], ["X-Test": "\u{7f}"]])
    func rejectsHeaderInjection(_ headers: HTTPHeaders) throws {
        #expect(throws: NetworkError.self) { try builder().build(Endpoint<Data>(headers: headers, decoder: .data)) }
    }

    @Test(arguments: [0.0, -1, .infinity, .nan]) func rejectsInvalidTimeout(_ timeout: Double) throws {
        let config = HTTPClientConfiguration(baseURL: try #require(URL(string: "https://example.com")), timeout: timeout)
        #expect(throws: NetworkError.self) { try RequestBuilder(configuration: config).build(Endpoint<Data>(decoder: .data)) }
    }
}
