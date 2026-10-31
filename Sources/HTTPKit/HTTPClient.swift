import Foundation

/// Immutable, Sendable coordinator. UI isolation and application/domain errors belong to the app.
public struct HTTPClient: Sendable {
    private let builder: RequestBuilder
    private let transport: any HTTPTransport
    private let authenticator: (any RequestAuthenticator)?
    private let retryPolicy: RetryPolicy
    private let clock: any NetworkClock
    private let random: @Sendable () -> Double
    private let observer: (any NetworkObserver)?

    /// Creates a client with optional, independently injectable network policies.
    /// Retry and observation are disabled by default; authentication is enabled per endpoint.
    public init(
        configuration: HTTPClientConfiguration,
        transport: any HTTPTransport = URLSessionTransport(),
        authenticator: (any RequestAuthenticator)? = nil,
        retryPolicy: RetryPolicy = .none,
        clock: any NetworkClock = SystemNetworkClock(),
        random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
        observer: (any NetworkObserver)? = nil
    ) {
        builder = RequestBuilder(configuration: configuration)
        self.transport = transport
        self.authenticator = authenticator
        self.retryPolicy = retryPolicy
        self.clock = clock
        self.random = random
        self.observer = observer
    }

    /// Executes an endpoint and returns its decoded value after HTTP status validation.
    /// Cancellation propagates as CancellationError; diagnostic failures retain their causes.
    public func send<Value>(_ endpoint: Endpoint<Value>) async throws -> Value {
        try await sendWithResponse(endpoint).value
    }

    /// Executes an endpoint while preserving the complete final HTTP response alongside its value.
    /// The caller owns the task lifetime; concurrent calls can share this immutable client.
    public func sendWithResponse<Value>(_ endpoint: Endpoint<Value>) async throws -> DecodedResponse<Value> {
        let requestID = UUID()
        let started = ContinuousClock.now
        var attempts = 0
        var status: Int?
        let decoded: DecodedResponse<Value>
        do {
            try Task.checkCancellation()
            let request = try builder.build(endpoint)
            let response = try await execute(request, endpoint: endpoint, attempts: &attempts, status: &status)
            try Task.checkCancellation()
            let value: Value
            do { value = try endpoint.decoder.decode(response) }
            catch is CancellationError { throw CancellationError() }
            catch { throw NetworkError.decoding(underlying: error, response: response) }
            try Task.checkCancellation()
            decoded = DecodedResponse(value: value, response: response)
        } catch {
            let cancelled = Self.isCancellation(error)
            await observer?.record(NetworkEvent(requestID: requestID, method: endpoint.method,
                attempts: attempts, statusCode: status, duration: started.duration(to: .now),
                outcome: cancelled ? .cancelled : .failure))
            if cancelled { throw CancellationError() }
            throw error
        }
        await observer?.record(NetworkEvent(requestID: requestID, method: endpoint.method,
            attempts: attempts, statusCode: status, duration: started.duration(to: .now), outcome: .success))
        // Observation is awaited, but must not turn cancellation into a returned success or emit twice.
        try Task.checkCancellation()
        return decoded
    }

    private func execute<Value>(
        _ original: URLRequest,
        endpoint: Endpoint<Value>,
        attempts: inout Int,
        status: inout Int?
    ) async throws -> HTTPResponse {
        var credential: HTTPAuthorization?
        if endpoint.requiresAuthentication {
            guard let authenticator else { throw NetworkError.missingAuthenticator }
            credential = try await authorization(from: authenticator)
        }
        var retries = 0
        var didRefresh = false
        let canReplay = endpoint.replayPolicy.permits(endpoint.method)
        while true {
            try Task.checkCancellation()
            var request = original
            if let credential {
                request.setValue(credential.headerValue, forHTTPHeaderField: "Authorization")
            }
            attempts += 1
            status = nil
            let response: HTTPResponse
            do {
                response = try await transport.execute(request)
            } catch {
                if Self.isCancellation(error) { throw CancellationError() }
                if canReplay, retries < retryPolicy.maximumRetries, retryPolicy.retries(error),
                   let delay = await delay(retry: retries, response: nil) {
                    retries += 1
                    try await clock.sleep(for: delay)
                    continue
                }
                if let error = error as? NetworkError { throw error }
                throw NetworkError.transport(underlying: error)
            }
            try Task.checkCancellation()
            status = response.statusCode
            if endpoint.acceptedStatusCodes.contains(response.statusCode) { return response }
            if response.statusCode == 401, canReplay, !didRefresh,
               let authenticator, let rejected = credential {
                didRefresh = true
                do { try await authenticator.refresh(after: rejected) }
                catch {
                    if Self.isCancellation(error) { throw CancellationError() }
                    throw NetworkError.authentication(underlying: error)
                }
                credential = try await authorization(from: authenticator)
                continue
            }
            if response.statusCode != 401, canReplay, retries < retryPolicy.maximumRetries,
               retryPolicy.statusCodes.contains(response.statusCode),
               let delay = await delay(retry: retries, response: response) {
                retries += 1
                try await clock.sleep(for: delay)
                continue
            }
            throw NetworkError.http(response)
        }
    }

    private func authorization(from authenticator: any RequestAuthenticator) async throws -> HTTPAuthorization {
        do {
            let credential = try await authenticator.authorization()
            guard !credential.headerValue.isEmpty else { throw NetworkError.invalidCredential }
            try RequestBuilder.validate(["Authorization": credential.headerValue])
            return credential
        } catch {
            if Self.isCancellation(error) { throw CancellationError() }
            throw NetworkError.authentication(underlying: error)
        }
    }

    private func delay(retry: Int, response: HTTPResponse?) async -> Duration? {
        retryPolicy.delay(retry: retry, response: response, now: await clock.now(), random: random())
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}
