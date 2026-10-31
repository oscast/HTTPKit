# HTTPKit

**Typed requests. Explicit policies. Testable by design.**

A reusable HTTP networking foundation for Swift apps, built on Foundation and Swift Concurrency. Keep your endpoints, models, and business rules in your app—not inside your network layer.

**iOS 18+ · macOS 15+ · Swift 6 language mode · Swift Package Manager · No external dependencies**

## Why HTTPKit?

Starting a new app should not mean rewriting request construction, HTTP validation, token refresh, cancellation, and test doubles.

HTTPKit provides those foundations without owning your UI, choosing an application architecture, or coupling your code to a particular backend. Use it from SwiftUI, UIKit, or another Swift module through your own services.

## Features

- **Typed endpoints:** associate each request with its response type.
- **Flexible responses:** JSON, raw data, explicit empty responses, or custom decoders.
- **Injectable transport:** use URLSession in production and deterministic fakes in tests.
- **Useful errors:** retain HTTP status, headers, body, and underlying causes.
- **Cooperative cancellation:** cancel in-flight requests, retry delays, and refresh waits.
- **Optional authentication:** opt in per endpoint; coordinate concurrent bearer-token refreshes.
- **Safe retries:** opt-in exponential backoff, full jitter, and `Retry-After` support.
- **Privacy-conscious diagnostics:** observe outcomes without recording URLs, credentials, or payloads.
- **Dedicated test support:** instance-scoped stubs, a virtual clock, and a recording observer.

## Requirements

| Component | Requirement |
|---|---|
| iOS | 18.0 or later, including iOS 26 |
| macOS | 15.0 or later |
| Swift language mode | Swift 6 |
| Package tools version | Swift 6.0, declared minimum |
| External dependencies | None |

The same implementation supports both iOS 18 and iOS 26. Deployment targets and compiler versions are separate concerns.

Local validation currently covers Swift 6.4 and Swift 6.3.3, with iOS 18.6 and iOS 26.5 simulators. The Swift 6.0 compiler check is included in the CI template but has not run yet. See [Validation](Docs/Validation.md) for the exact evidence and remaining checks.

## Installation

### Xcode

1. Select **File → Add Package Dependencies**.
2. Enter `https://github.com/oscast/HTTPKit.git`.
3. Select a version rule starting at `0.1.0`.
4. Add **HTTPKit** to your app target.
5. Optionally add **HTTPKitTestSupport** to your test target only.

For local development, use **Add Local** and select this package folder.

### Package.swift

Add this entry to your package dependencies:

```swift
.package(url: "https://github.com/oscast/HTTPKit.git", from: "0.1.0")
```

Add the appropriate product to each target:

```swift
.product(name: "HTTPKit", package: "HTTPKit")
// Test targets only:
.product(name: "HTTPKitTestSupport", package: "HTTPKit")
```

## Quick start

Define a model and a service in your app. Keep one client per backend/configuration and inject it into the service.

```swift
import Foundation
import HTTPKit

struct Product: Decodable, Sendable {
    let id: Int
    let name: String
}

struct ProductService: Sendable {
    let client: HTTPClient

    func products(page: Int = 1) async throws -> [Product] {
        let endpoint = Endpoint<[Product]>.json(
            path: ["products"],
            query: [URLQueryItem(name: "page", value: String(page))]
        )
        return try await client.send(endpoint)
    }
}

func makeProductService(baseURL: URL) -> ProductService {
    let client = HTTPClient(configuration: .init(baseURL: baseURL))
    return ProductService(client: client)
}
```

Path elements are encoded as individual segments, including embedded slashes. Query items preserve repeated keys. Default headers are merged case-insensitively with endpoint headers.

### Send JSON

```swift
struct NewProduct: Encodable {
    let name: String
}

func createProduct(client: HTTPClient, name: String) async throws -> Product {
    let endpoint = Endpoint<Product>.json(
        path: ["products"],
        method: .post,
        body: try .json(NewProduct(name: name)),
        requiresAuthentication: true,
        configureDecoder: { $0.keyDecodingStrategy = .convertFromSnakeCase }
    )
    return try await client.send(endpoint)
}
```

Each JSON response uses a fresh decoder. Custom formats can use `ResponseDecoder`; form-encoded or other request payloads can use `HTTPBody(data:contentType:)`.

### Empty responses and raw data

```swift
func deleteProduct(client: HTTPClient, id: Int) async throws {
    let endpoint = Endpoint<EmptyResponse>(
        path: ["products", String(id)],
        method: .delete,
        requiresAuthentication: true,
        decoder: .empty
    )
    _ = try await client.send(endpoint)
}

func loadFile(client: HTTPClient, name: String) async throws -> Data {
    try await client.send(Endpoint<Data>(path: ["files", name], decoder: .data))
}
```

Use `sendWithResponse` when you also need HTTP metadata. The default accepted status range is `200..<300`; individual endpoints can override it. `.empty` deliberately ignores the body—it does not turn invalid JSON into a successful empty value.

## Authentication

Authentication is optional and enabled explicitly on each endpoint.

```swift
func makeAuthenticatedClient(
    baseURL: URL,
    storedAccessToken: String,
    refresh: @escaping @Sendable () async throws -> String
) throws -> (client: HTTPClient, authenticator: BearerTokenAuthenticator) {
    let authenticator = try BearerTokenAuthenticator(
        accessToken: storedAccessToken,
        refresh: refresh
    )
    let client = HTTPClient(
        configuration: .init(baseURL: baseURL),
        authenticator: authenticator,
        retryPolicy: try RetryPolicy(maximumRetries: 2)
    )
    return (client, authenticator)
}
```

- The app owns secure token storage, refresh-token rotation, and backend-specific authentication rules.
- Use a separate unauthenticated client inside `refresh` to avoid recursion.
- Concurrent refresh callers share one refresh operation; late `401` responses for an older credential do not start another refresh.
- Each caller can cancel its own refresh wait. Cancelling the last waiter cancels the shared operation.
- A logical request can refresh and replay at most once, and only when its replay policy allows it.
- On logout, cancel active request tasks, call `cancelRefresh`, discard the client/authenticator, and clear app-owned credentials. Cancelling refresh alone does not revoke or erase the current token.
- For account or token changes, `replaceAccessToken` invalidates pending refresh work and ignores late results.

Implement `RequestAuthenticator` for a different authorization scheme. Do not put shared credentials in `defaultHeaders` if some endpoints must remain public. An injected URLSession may also attach its own cookies or headers.

## Retry behavior

Retries are **disabled by default**. Enable them with `RetryPolicy(maximumRetries:)`.

| Policy | Behavior |
|---|---|
| `.idempotentMethods` | Allows replay for GET, HEAD, PUT, DELETE, and OPTIONS |
| `.never` | Disables replay, including replay after authentication refresh |
| `.allowed` | Caller explicitly guarantees that repeating the operation is safe |

**POST and PATCH are not automatically replayed**, including after authentication refresh. Use `.allowed` only when your backend guarantees replay safety, such as a server-enforced idempotency key.

Transient retries use bounded exponential backoff with full jitter. `Retry-After` accepts seconds or an HTTP date. If the required server delay exceeds `maximumDelay`, the request fails rather than retrying too early.

The default retryable status codes are 408, 429, 500, 502, 503, and 504. Only selected transient `URLError` codes are retried; TLS, decoding, construction, and cancellation failures are not. The retry budget is additional to the first attempt; authentication replay can add one more attempt.

Timeouts apply per attempt, not to the whole logical request. Cancellation and deadlines remain the caller's responsibility. URLSession may perform additional internal HTTP recovery not represented by the transport-attempt count.

## Error handling and cancellation

`NetworkError` distinguishes request configuration, invalid headers or paths, insecure connections, non-HTTP responses, authentication, transport, HTTP status, and decoding failures.

HTTP and decoding failures preserve the response. Authentication, transport, and decoding failures preserve the underlying cause. Your app maps those errors to domain behavior and localized UI messages.

Cancellation propagates as `CancellationError` and is never retried. Custom transports, authenticators, and decoders must cooperate with cancellation.

> Do not log an entire `NetworkError` in production: preserved response bodies and underlying errors may contain sensitive information.

## Testing without the network

Use `HTTPKitTestSupport` in your test target:

```swift
import Testing
import HTTPKitTestSupport

@Test func loadsProducts() async throws {
    let transport = StubTransport([
        .response(HTTPResponse(
            statusCode: 200,
            body: Data(#"[{"id":1,"name":"Keyboard"}]"#.utf8)
        ))
    ])
    let baseURL = try #require(URL(string: "https://example.com"))
    let client = HTTPClient(configuration: .init(baseURL: baseURL), transport: transport)
    let products = try await ProductService(client: client).products()

    #expect(products.map(\.name) == ["Keyboard"])
    #expect(await transport.requests.count == 1)
}
```

`StubTransport` can return responses, throw errors, or execute async handlers. Missing stubs fail instead of reaching the internet. `RecordingClock` advances virtual time without sleeping, and `RecordingObserver` captures completion events.

For ViewModel or feature tests, inject your app's service protocol instead of mocking the entire HTTP stack.

## Security and observability

- HTTPS is required by default; Foundation performs normal TLS validation.
- The default URLSession adapter rejects cross-origin redirects, port changes, embedded URL credentials, and HTTPS-to-HTTP downgrades.
- Insecure HTTP is an explicit development opt-in and does not bypass your app's ATS policy.
- Optional observers receive a request UUID, method, attempt count, final HTTP status when available, duration, and outcome—never URLs, headers, credentials, or payloads.
- `OSLogNetworkObserver` keeps correlation identifiers private. Observers are awaited and should complete promptly.

The event describes the operation before observation; a caller cancelling during observation still receives cancellation, without a second event.

See [Security](Docs/Security.md) for the threat model and responsibilities that remain with your app.

## Architecture

```text
App / Feature
    ↓
App-owned service + DTOs + business rules
    ↓
Endpoint<Response>
    ↓
HTTPClient
    ├── RequestBuilder
    ├── Optional authentication and retry policies
    ├── Response validation and decoding
    └── HTTPTransport → URLSessionTransport
```

Protocols exist at external boundaries—transport, authentication, clock, and observation—not for every type. `HTTPClient` is an immutable `Sendable` value; shared token state is protected by an actor. The package does not require MainActor isolation or a particular UI architecture.

## Documentation

| Guide | Contents |
|---|---|
| [API reference](Docs/API.md) | Public types, request lifecycle, defaults, and error contracts |
| [Architecture](Docs/Architecture.md) | Boundaries, concurrency, ownership, trade-offs, and migration |
| [Security](Docs/Security.md) | Threat model, credentials, redirects, logging, and application responsibilities |
| [Testing](Docs/Testing.md) | Test doubles, deterministic async tests, simulator scripts, and CI |
| [Validation](Docs/Validation.md) | Checks actually executed and what remains unverified |
| [Examples](Examples/) | Compiled REST services and composition-root examples |
| [Changelog](CHANGELOG.md) | Package changes and release status |

Public API contract comments and examples are written in English. Documentation is currently Markdown and source comments; no generated DocC website is published.

## Run the tests

```sh
swift test
swift test -c release
bash Scripts/test-ios.sh 18
bash Scripts/test-ios.sh 26
```

The current local validation record contains **51 tests across 5 suites**, passing in macOS Debug/Release and on iOS 18.6/iOS 26.5 simulators. The suite also passed 10 additional repeated runs. Tests use isolated fakes and URLProtocol fixtures; they do not require external API credentials or an internet connection.

A [CI template](Docs/CI.workflow.yml) covers the declared minimum compiler and iOS 18/26 simulators. Automatic GitHub Actions execution is not enabled yet: publishing workflow files requires an additional GitHub authorization scope. A template is not a passing CI run; see [Validation](Docs/Validation.md).

## Scope

This version buffers response bodies in memory. It is not a large-file downloader and does not enforce a hard response-size limit.

Streaming/SSE, WebSockets, multipart helpers, upload progress, background transfers, persistent offline queues, and business-level caching are not included. Add them behind explicit contracts and tests when your app actually needs them.

## Author

**Oscar Castillo**

[GitHub: @oscast](https://github.com/oscast) · [goldoac@gmail.com](mailto:goldoac@gmail.com)

## Release status

Initial public version: **0.1.0**. See the [changelog](CHANGELOG.md) and [validation record](Docs/Validation.md) before adoption.

## License

Licensed under the [MIT License](LICENSE).

Copyright (c) 2026 Oscar Castillo.
