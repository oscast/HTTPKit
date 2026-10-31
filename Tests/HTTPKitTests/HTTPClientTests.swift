import Foundation
import Testing
import HTTPKit
import HTTPKitTestSupport
import HTTPKitExamples

struct TestItem: Codable, Sendable, Equatable { let firstName: String }

func makeClient(
    _ transport: any HTTPTransport,
    authenticator: (any RequestAuthenticator)? = nil,
    retryPolicy: RetryPolicy = .none,
    clock: any NetworkClock = RecordingClock(),
    random: @escaping @Sendable () -> Double = { 1 },
    observer: (any NetworkObserver)? = nil
) throws -> HTTPClient {
    HTTPClient(configuration: .init(baseURL: try #require(URL(string: "https://example.com/v1"))),
               transport: transport, authenticator: authenticator, retryPolicy: retryPolicy,
               clock: clock, random: random, observer: observer)
}

@Suite("HTTP client")
struct HTTPClientTests {
    @Test func decodesAndPreservesHTTPMetadata() async throws {
        let transport = StubTransport([.response(.init(statusCode: 201, headers: ["X-Request-ID": "abc"],
            body: Data(#"{"first_name":"Ana"}"#.utf8)))])
        let endpoint = Endpoint<TestItem>.json(path: ["users"], configureDecoder: { $0.keyDecodingStrategy = .convertFromSnakeCase })
        let result = try await makeClient(transport).sendWithResponse(endpoint)
        #expect(result.value == TestItem(firstName: "Ana"))
        #expect(result.response.statusCode == 201)
        #expect(result.response.headers["x-request-id"] == "abc")
    }

    @Test func acceptsEmptyAndBinaryResponsesExplicitly() async throws {
        let transport = StubTransport([.response(.init(statusCode: 204)), .response(.init(statusCode: 200, body: Data([0, 255])))])
        let client = try makeClient(transport)
        #expect(try await client.send(Endpoint<EmptyResponse>(method: .delete, decoder: .empty)) == EmptyResponse())
        #expect(try await client.send(Endpoint<Data>(decoder: .data)) == Data([0, 255]))
    }

    @Test func preservesHTTPFailureBodyAndHeaders() async throws {
        let response = HTTPResponse(statusCode: 422, headers: ["X-Error": "validation"], body: Data("invalid email".utf8))
        let client = try makeClient(StubTransport([.response(response)]))
        do {
            _ = try await client.send(Endpoint<Data>(decoder: .data))
            Issue.record("Expected HTTP failure")
        } catch NetworkError.http(let actual) {
            #expect(actual == response)
        }
    }

    @Test func retainsDecodingCauseAndDoesNotRetry() async throws {
        let transport = StubTransport([.response(.init(statusCode: 200, body: Data("invalid".utf8)))])
        let client = try makeClient(transport, retryPolicy: RetryPolicy(maximumRetries: 3))
        do {
            _ = try await client.send(Endpoint<TestItem>.json())
            Issue.record("Expected decoding failure")
        } catch NetworkError.decoding(let underlying, let response) {
            #expect(underlying is DecodingError)
            #expect(response.statusCode == 200)
        }
        #expect(await transport.requests.count == 1)
    }

    @Test func transportCauseIsPreserved() async throws {
        let client = try makeClient(StubTransport([.failure(URLError(.secureConnectionFailed))]))
        do {
            _ = try await client.send(Endpoint<Data>(decoder: .data))
            Issue.record("Expected transport failure")
        } catch NetworkError.transport(let underlying) {
            #expect((underlying as? URLError)?.code == .secureConnectionFailed)
        }
    }

    @Test func normalizesURLSessionCancellation() async throws {
        let observer = RecordingObserver()
        let client = try makeClient(StubTransport([.failure(URLError(.cancelled))]), observer: observer)
        await #expect(throws: CancellationError.self) { try await client.send(Endpoint<Data>(decoder: .data)) }
        #expect(await observer.events.map(\.outcome) == [.cancelled])
    }

    @Test func cancelledCallerNeverStartsTransport() async throws {
        let transport = StubTransport([])
        let client = try makeClient(transport)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.send(Endpoint<Data>(decoder: .data))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.requests.isEmpty)
    }

    @Test func supportsCustomStatusValidationAndDecoder() async throws {
        let client = try makeClient(StubTransport([.response(.init(statusCode: 304))]))
        let endpoint = Endpoint<String>(acceptedStatusCodes: 200..<400, decoder: .init { "status=\($0.statusCode)" })
        #expect(try await client.send(endpoint) == "status=304")
    }

    @Test func observerEmitsExactlyOnePrivacySafeCompletion() async throws {
        let observer = RecordingObserver()
        let transport = StubTransport([.response(.init(statusCode: 503)), .response(.init(statusCode: 200))])
        let client = try makeClient(transport, retryPolicy: RetryPolicy(maximumRetries: 1), observer: observer)
        _ = try await client.send(Endpoint<Data>(path: ["private-user-id"], query: [.init(name: "secret", value: "private")], decoder: .data))
        let event = try #require(await observer.events.first)
        #expect(await observer.events.count == 1)
        #expect(event.attempts == 2)
        #expect(event.statusCode == 200)
        #expect(event.outcome == .success)
        #expect(!String(describing: event).contains("private"))
    }

    @Test func serviceExampleRunsWithoutInternet() async throws {
        let transport = StubTransport([.response(.init(statusCode: 200, body: Data(#"[{"id":1,"name":"Ana"}]"#.utf8)))])
        let users = try await UsersService(client: makeClient(transport)).users()
        #expect(users.map(\.name) == ["Ana"])
    }

    @Test func parallelRequestsKeepDecodersIndependent() async throws {
        let transport = StubTransport((0..<40).map { _ in .handler { request in
            let snake = request.value(forHTTPHeaderField: "X-Format") == "snake"
            return HTTPResponse(statusCode: 200, body: Data((snake
                ? #"{"first_name":"snake"}"# : #"{"firstName":"camel"}"#).utf8))
        } })
        let client = try makeClient(transport)
        try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<40 {
                group.addTask {
                    let snake = index.isMultiple(of: 2)
                    let endpoint = Endpoint<TestItem>.json(headers: ["X-Format": snake ? "snake" : "camel"],
                        configureDecoder: { $0.keyDecodingStrategy = snake ? .convertFromSnakeCase : .useDefaultKeys })
                    return try await client.send(endpoint).firstName
                }
            }
            var values: [String] = []
            for try await value in group { values.append(value) }
            #expect(values.filter { $0 == "snake" }.count == 20)
            #expect(values.filter { $0 == "camel" }.count == 20)
        }
    }

    @Test func inFlightCancellationReachesTransportAndDoesNotRetry() async throws {
        let started = Gate()
        let transport = StubTransport([.handler { _ in
            await started.open()
            try await Task.sleep(for: .seconds(60))
            return HTTPResponse(statusCode: 200)
        }])
        let client = try makeClient(transport, retryPolicy: RetryPolicy(maximumRetries: 2))
        let task = Task { try await client.send(Endpoint<Data>(decoder: .data)) }
        await started.wait()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.requests.count == 1)
    }

    @Test func cancellationDuringObservationDoesNotReturnSuccessOrEmitTwice() async throws {
        let observer = SuspendingObserver()
        let client = try makeClient(StubTransport([.response(.init(statusCode: 200))]), observer: observer)
        let task = Task { try await client.send(Endpoint<Data>(decoder: .data)) }
        await observer.started.wait()
        task.cancel()
        await observer.finish.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await observer.events.count == 1)
    }
}

private actor SuspendingObserver: NetworkObserver {
    let started = Gate()
    let finish = Gate()
    private(set) var events: [NetworkEvent] = []
    func record(_ event: NetworkEvent) async {
        events.append(event)
        await started.open()
        await finish.wait()
    }
}
