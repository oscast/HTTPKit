import Foundation
import Testing
import HTTPKit
import HTTPKitTestSupport

actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

@Suite("Authentication", .timeLimit(.minutes(1)))
struct AuthenticationTests {
    @Test func refreshesOnceAndUsesNewToken() async throws {
        let counter = Counter()
        let auth = try BearerTokenAuthenticator(accessToken: "old") { await counter.increment(); return "new" }
        let transport = StubTransport([.response(.init(statusCode: 401)), .response(.init(statusCode: 200))])
        _ = try await makeClient(transport, authenticator: auth).send(Endpoint<Data>(requiresAuthentication: true, decoder: .data))
        #expect(await transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer old", "Bearer new"])
        #expect(await counter.value == 1)
    }

    @Test func second401StopsRatherThanLooping() async throws {
        let counter = Counter()
        let auth = try BearerTokenAuthenticator(accessToken: "old") { await counter.increment(); return "new" }
        let transport = StubTransport([.response(.init(statusCode: 401)), .response(.init(statusCode: 401))])
        let client = try makeClient(transport, authenticator: auth, retryPolicy: RetryPolicy(maximumRetries: 3, statusCodes: [401]))
        await #expect(throws: NetworkError.self) {
            try await client.send(Endpoint<Data>(requiresAuthentication: true, decoder: .data))
        }
        #expect(await counter.value == 1)
        #expect(await transport.requests.count == 2)
    }

    @Test func publicEndpointNeverAsksForCredentials() async throws {
        let auth = try BearerTokenAuthenticator(accessToken: "secret") { Issue.record("Unexpected refresh"); return "new" }
        let transport = StubTransport([.response(.init(statusCode: 200))])
        _ = try await makeClient(transport, authenticator: auth).send(Endpoint<Data>(decoder: .data))
        #expect(await transport.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func authenticatedPOSTIsNotAutomaticallyReplayed() async throws {
        let counter = Counter()
        let auth = try BearerTokenAuthenticator(accessToken: "old") { await counter.increment(); return "new" }
        let transport = StubTransport([.response(.init(statusCode: 401))])
        let client = try makeClient(transport, authenticator: auth)
        await #expect(throws: NetworkError.self) {
            try await client.send(Endpoint<Data>(method: .post, requiresAuthentication: true, decoder: .data))
        }
        #expect(await counter.value == 0)
        #expect(await transport.requests.count == 1)
    }

    @Test func missingAuthenticatorFailsBeforeTransport() async throws {
        let transport = StubTransport([])
        let client = try makeClient(transport)
        await #expect(throws: NetworkError.self) {
            try await client.send(Endpoint<Data>(requiresAuthentication: true, decoder: .data))
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func concurrentRefreshesShareWorkAndLate401DoesNotRefreshAgain() async throws {
        let counter = Counter()
        let started = Gate()
        let finish = Gate()
        let auth = try BearerTokenAuthenticator(accessToken: "old") {
            await counter.increment()
            await started.open()
            await finish.wait()
            return "new"
        }
        let rejected = try await auth.authorization()
        let first = Task { try await auth.refresh(after: rejected) }
        await started.wait()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<30 { group.addTask { try await auth.refresh(after: rejected) } }
            await finish.open()
            try await group.waitForAll()
        }
        try await first.value
        try await auth.refresh(after: rejected)
        #expect(await counter.value == 1)
        #expect(try await auth.authorization().headerValue == "Bearer new")
    }

    @Test func cancellingLastWaiterReturnsPromptlyAndIgnoresLateRefreshResult() async throws {
        let started = Gate()
        let finish = Gate()
        let returned = Gate()
        let auth = try BearerTokenAuthenticator(accessToken: "old") {
            await started.open()
            await finish.wait() // Deliberately models a dependency which ignores cancellation.
            await returned.open()
            return "stale"
        }
        let rejected = try await auth.authorization()
        let task = Task { try await auth.refresh(after: rejected) }
        await started.wait()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await auth.replaceAccessToken("replacement")
        await finish.open()
        await returned.wait()
        #expect(try await auth.authorization().headerValue == "Bearer replacement")
    }

    @Test func replaceTokenInvalidatesInFlightRefresh() async throws {
        let started = Gate()
        let finish = Gate()
        let auth = try BearerTokenAuthenticator(accessToken: "old") {
            await started.open(); await finish.wait(); return "stale"
        }
        let rejected = try await auth.authorization()
        let task = Task { try await auth.refresh(after: rejected) }
        await started.wait()
        try await auth.replaceAccessToken("new-account")
        await #expect(throws: CancellationError.self) { try await task.value }
        await finish.open()
        #expect(try await auth.authorization().headerValue == "Bearer new-account")
    }

    @Test func cancellingOneCallerDoesNotFailAnotherCaller() async throws {
        let started = Gate()
        let finish = Gate()
        let auth = try BearerTokenAuthenticator(accessToken: "old") {
            await started.open()
            await finish.wait()
            return "new"
        }
        let rejected = try await auth.authorization()
        let cancelled = Task { try await auth.refresh(after: rejected) }
        let survivor = Task { try await auth.refresh(after: rejected) }
        await started.wait()
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        await finish.open()
        try await survivor.value
        #expect(try await auth.authorization().headerValue == "Bearer new")
    }

    @Test func credentialRevisionChangesEvenWhenServerReturnsSameToken() async throws {
        let counter = Counter()
        let auth = try BearerTokenAuthenticator(accessToken: "same") { await counter.increment(); return "same" }
        let old = try await auth.authorization()
        try await auth.refresh(after: old)
        let new = try await auth.authorization()
        #expect(old != new)
        #expect(old.headerValue == new.headerValue)
        try await auth.refresh(after: old)
        #expect(await counter.value == 1)
    }

    @Test func rejectsHeaderInjectionFromCustomAuthenticator() async throws {
        struct InvalidAuthenticator: RequestAuthenticator {
            func authorization() async throws -> HTTPAuthorization { .init(headerValue: "Bearer x\r\nX: injected") }
            func refresh(after rejected: HTTPAuthorization) async throws {}
        }
        let transport = StubTransport([])
        let client = try makeClient(transport, authenticator: InvalidAuthenticator())
        await #expect(throws: NetworkError.self) {
            try await client.send(Endpoint<Data>(requiresAuthentication: true, decoder: .data))
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func refreshFailurePreservesCause() async throws {
        struct RefreshError: Error {}
        let auth = try BearerTokenAuthenticator(accessToken: "old") { throw RefreshError() }
        let client = try makeClient(StubTransport([.response(.init(statusCode: 401))]), authenticator: auth)
        do {
            _ = try await client.send(Endpoint<Data>(requiresAuthentication: true, decoder: .data))
            Issue.record("Expected authentication failure")
        } catch NetworkError.authentication(let underlying) {
            #expect(underlying is RefreshError)
        }
    }

    @Test(arguments: ["", "hello world", "token\r\nX: yes", "é"])
    func rejectsInvalidBearerTokens(_ token: String) {
        #expect(throws: NetworkError.self) { try BearerTokenAuthenticator(accessToken: token) { "new" } }
    }
}
