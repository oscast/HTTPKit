import Foundation
import Testing
import HTTPKit
import HTTPKitTestSupport

@Suite("Retry policy")
struct RetryTests {
    @Test func usesBoundedExponentialBackoff() async throws {
        let clock = RecordingClock()
        let transport = StubTransport([
            .failure(URLError(.timedOut)), .response(.init(statusCode: 503)), .response(.init(statusCode: 200))
        ])
        let client = try makeClient(transport, retryPolicy: RetryPolicy(maximumRetries: 2), clock: clock)
        _ = try await client.send(Endpoint<Data>(decoder: .data))
        #expect(await clock.sleeps == [.milliseconds(500), .seconds(1)])
        #expect(await transport.requests.count == 3)
    }

    @Test func respectsRetryBudget() async throws {
        let transport = StubTransport((0..<3).map { _ in .response(.init(statusCode: 503)) })
        let client = try makeClient(transport, retryPolicy: RetryPolicy(maximumRetries: 1))
        await #expect(throws: NetworkError.self) { try await client.send(Endpoint<Data>(decoder: .data)) }
        #expect(await transport.requests.count == 2)
    }

    @Test func jitterIsInjectedAndBackoffIsCapped() async throws {
        let clock = RecordingClock()
        let transport = StubTransport([.response(.init(statusCode: 503)), .response(.init(statusCode: 503)),
            .response(.init(statusCode: 503)), .response(.init(statusCode: 200))])
        let client = try makeClient(transport, retryPolicy: RetryPolicy(maximumRetries: 3, baseDelay: 1, maximumDelay: 2),
            clock: clock, random: { 0.25 })
        _ = try await client.send(Endpoint<Data>(decoder: .data))
        #expect(await clock.sleeps == [.milliseconds(250), .milliseconds(500), .milliseconds(500)])
    }

    @Test func TLSFailuresAreNeverRetried() async throws {
        let transport = StubTransport([.failure(URLError(.serverCertificateUntrusted))])
        let client = try makeClient(transport, retryPolicy: RetryPolicy(maximumRetries: 3))
        await #expect(throws: NetworkError.self) { try await client.send(Endpoint<Data>(decoder: .data)) }
        #expect(await transport.requests.count == 1)
    }

    @Test(arguments: [HTTPMethod.post, .patch]) func doesNotReplayUnsafeMethods(_ method: HTTPMethod) async throws {
        let transport = StubTransport([.response(.init(statusCode: 503))])
        let client = try makeClient(transport, retryPolicy: RetryPolicy(maximumRetries: 2))
        await #expect(throws: NetworkError.self) { try await client.send(Endpoint<Data>(method: method, decoder: .data)) }
        #expect(await transport.requests.count == 1)
    }

    @Test func explicitReplayAllowsIdempotencyKeyPOST() async throws {
        let transport = StubTransport([.response(.init(statusCode: 503)), .response(.init(statusCode: 200))])
        let client = try makeClient(transport, retryPolicy: RetryPolicy(maximumRetries: 1))
        let endpoint = Endpoint<Data>(method: .post, headers: ["Idempotency-Key": "operation-1"], replayPolicy: .allowed, decoder: .data)
        _ = try await client.send(endpoint)
        #expect(await transport.requests.count == 2)
        #expect(await transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Idempotency-Key") == "operation-1" })
    }

    @Test func neverReplayOverridesIdempotentMethod() async throws {
        let transport = StubTransport([.response(.init(statusCode: 503))])
        let client = try makeClient(transport, retryPolicy: RetryPolicy(maximumRetries: 2))
        await #expect(throws: NetworkError.self) {
            try await client.send(Endpoint<Data>(replayPolicy: .never, decoder: .data))
        }
        #expect(await transport.requests.count == 1)
    }

    @Test(arguments: ["3", "Thu, 01 Jan 1970 00:00:03 GMT"])
    func honorsRetryAfter(_ value: String) async throws {
        let clock = RecordingClock()
        let transport = StubTransport([.response(.init(statusCode: 429, headers: ["Retry-After": value])), .response(.init(statusCode: 200))])
        _ = try await makeClient(transport, retryPolicy: RetryPolicy(maximumRetries: 1), clock: clock).send(Endpoint<Data>(decoder: .data))
        #expect(await clock.sleeps == [.seconds(3)])
    }

    @Test(arguments: ["3600", String(repeating: "9", count: 500)])
    func doesNotRetryEarlierThanLongServerDelay(_ delay: String) async throws {
        let clock = RecordingClock()
        let transport = StubTransport([.response(.init(statusCode: 429, headers: ["Retry-After": delay]))])
        let client = try makeClient(transport, retryPolicy: RetryPolicy(maximumRetries: 2), clock: clock)
        await #expect(throws: NetworkError.self) { try await client.send(Endpoint<Data>(decoder: .data)) }
        #expect(await clock.sleeps.isEmpty)
        #expect(await transport.requests.count == 1)
    }

    @Test func retryIsOffByDefault() async throws {
        let transport = StubTransport([.failure(URLError(.timedOut))])
        let client = try makeClient(transport)
        await #expect(throws: NetworkError.self) { try await client.send(Endpoint<Data>(decoder: .data)) }
        #expect(await transport.requests.count == 1)
    }

    @Test func cancellationDuringBackoffDoesNotStartNextAttempt() async throws {
        let clock = BlockingClock()
        let transport = StubTransport([.response(.init(statusCode: 503)), .response(.init(statusCode: 200))])
        let client = try makeClient(transport, retryPolicy: RetryPolicy(maximumRetries: 1), clock: clock)
        let task = Task { try await client.send(Endpoint<Data>(decoder: .data)) }
        await clock.started.wait()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.requests.count == 1)
    }

    @Test func rejectsInvalidPolicyConfiguration() {
        #expect(throws: NetworkError.self) { try RetryPolicy(maximumRetries: -1) }
        #expect(throws: NetworkError.self) { try RetryPolicy(maximumRetries: 101) }
        #expect(throws: NetworkError.self) { try RetryPolicy(maximumRetries: 1, baseDelay: -.infinity) }
        #expect(throws: NetworkError.self) { try RetryPolicy(maximumRetries: 1, maximumDelay: 100_000) }
    }
}

/// Deterministic one-shot signal. No sleeps, polling or shared global test state.
actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

struct BlockingClock: NetworkClock {
    let started = Gate()
    func now() async -> Date { Date(timeIntervalSince1970: 0) }
    func sleep(for duration: Duration) async throws {
        await started.open()
        // A bounded guard only; test synchronization uses the signal above, not elapsed time.
        try await Task.sleep(for: .seconds(60))
    }
}
