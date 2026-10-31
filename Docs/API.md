# API reference

This guide describes the current public API. For complete signatures, open the declarations in `Sources/HTTPKit/`; Xcode Quick Help also displays their contract comments.

## Default behavior

| Setting | Default |
|---|---|
| HTTP method | GET |
| Accepted status codes | `200..<300` |
| Request timeout | 30 seconds per transport attempt |
| Authentication | Off unless the endpoint explicitly requires it |
| Transient retries | Off (`RetryPolicy.none`) |
| Replay eligibility | Idempotent methods only |
| Transport | URLSession with an ephemeral session |
| Insecure HTTP | Rejected unless explicitly enabled |
| Observation | Off unless an observer is injected |
| Response-size limit | No hard limit; response data is buffered in memory |

## Client and configuration

### `HTTPClient`

An immutable `Sendable` coordinator initialized with configuration and optional transport, authenticator, retry policy, clock, random source, and observer.

- `send(_:) async throws -> Value` returns the endpoint's decoded value.
- `sendWithResponse(_:) async throws -> DecodedResponse<Value>` returns both the decoded value and the complete final HTTP response.

The app owns the task lifetime. Network work is not tied to a UI framework or global MainActor. Concurrent calls can share a client; mutable external dependencies must honor their Sendable contracts.

Built-in failures use `NetworkError`, and cancellation is normalized to `CancellationError`. Custom dependencies may have additional failure behavior; in particular, a custom clock's non-cancellation sleep errors propagate unchanged.

### `HTTPClientConfiguration`

- `baseURL`: trusted backend URL. HTTPS is required by default; embedded credentials and fragments are rejected.
- `defaultHeaders`: headers merged with endpoint headers, with endpoint values taking precedence case-insensitively. Per-endpoint authentication overrides Authorization when enabled.
- `timeout`: a finite, positive per-attempt request timeout. This is not an end-to-end deadline.
- `allowsInsecureHTTP`: explicit development opt-in; it does not modify ATS settings.

Create one client per backend/configuration and inject it into app-owned services. Do not use default headers for a credential that should only accompany selected endpoints.

### `RequestBuilder`

`build(_:) throws -> URLRequest` creates a relative request, validates configuration and headers, and sets the method, timeout, body, and merged headers. It does not execute requests or obtain credentials.

Path elements are individual, unescaped segments. Empty, `.` and `..` segments are rejected; reserved characters, including embedded slashes, are percent-encoded. Query items preserve duplicate names and nil values. Existing base-URL query items are retained.

## Endpoints and decoding

### `Endpoint<Response: Sendable>`

A value describing path segments, method, query items, headers, body, authentication requirement, replay policy, accepted status range, and response decoder.

Use `.json(...)` when the response is also Decodable. To change its accepted status range, configure the resulting endpoint value or use the full initializer.

An endpoint does not own a backend URL or business service. The client supplies backend configuration; the app supplies domain meaning.

### `ResponseDecoder<Value: Sendable>`

A Sendable closure transforming the entire `HTTPResponse` into a value.

- `.json(configure:)`: creates a fresh JSONDecoder for each decode; requires a Decodable result.
- `.data`: returns the raw Data body.
- `.empty`: returns EmptyResponse and intentionally ignores the body.
- `init(_:)`: accepts custom synchronous response interpretation, including content-type validation or a non-JSON format.

The client validates status before decoding. A decoder must not mutate unsafely shared state; expensive custom decoding and cancellation cooperation remain its implementation's responsibility.

### `HTTPBody`

Stores Data and an optional content type. `.json(_:configure:)` creates a new JSONEncoder and encodes immediately. Encoding failures are thrown at endpoint construction time, not deferred or wrapped as transport errors.

RequestBuilder sets the body's content type only if no header already supplies one. A JSON response decoder does not automatically set an Accept header.

## HTTP values

- **`HTTPMethod`**: GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS. `isIdempotent` classifies replay defaults; apps can override replay eligibility per endpoint.
- **`HTTPHeaders`**: case-insensitive field names with lowercase storage and one value per field. Supports dictionary literals, subscripting, merging, and read-only access to the stored fields.
- **`HTTPResponse`**: status code, headers, body, and optional URL. It is a Sendable, Equatable snapshot suitable for fakes and application-level error interpretation.
- **`DecodedResponse<Value>`**: decoded `value` plus the original `response`.
- **`EmptyResponse`**: explicit success value for endpoints whose body should be ignored.

Response headers reflect Foundation's interpretation, not raw repeated HTTP fields. Cookie handling belongs to the session, not HTTPHeaders.

## Transport

### `HTTPTransport`

`execute(_:) async throws -> HTTPResponse` is the network/testing seam. Implementations return HTTP responses even for failure status codes; HTTPClient applies endpoint status validation. Implementations should cooperate with task cancellation and document their TLS, redirect, buffering, and ownership behavior.

### `URLSessionTransport`

Uses `URLSession.data(for:delegate:)`. The default session is ephemeral. An injected session is retained, not reconfigured or invalidated; the caller owns its lifecycle.

The adapter rejects non-HTTP URLResponses. Its task delegate only follows redirects that preserve scheme, hostname, and effective port and contain no embedded credentials. Rejected redirects remain HTTP responses, normally rejected by the endpoint's accepted status range.

This is an in-memory data transport, not a streaming or large-file transfer abstraction.

## Authentication

### `HTTPAuthorization`

An Authorization header value with an opaque credential revision. Preserve and reuse an instance while the credential is unchanged; create a new instance for a new revision, even if its header text is identical. The header value is sensitive: do not log it.

### `RequestAuthenticator`

- `authorization() async throws`: returns the current credential.
- `refresh(after:) async throws`: handles rejection of a particular credential revision. Implementations decide whether refresh is possible, coalesce work if needed, and ignore stale rejection reports.

The client requests credentials only for authenticated endpoints and validates the returned Authorization header. A 401 can cause at most one refresh/replay per logical request, subject to replay eligibility.

### `BearerTokenAuthenticator`

An actor initialized with an access token and an async refresh closure returning the next token. Initial and refreshed tokens must be nonempty printable ASCII without whitespace.

The refresh closure owns backend-specific calls and persistence, including refresh-token rotation. It must not use the same authenticated client recursively or capture the authenticator in a cycle.

- Concurrent waiters share a refresh operation and can cancel independently.
- Cancelling the last waiter cancels the refresh task; a late result cannot change credentials.
- `replaceAccessToken(_:)` invalidates pending refresh work and installs a new revision.
- `cancelRefresh()` cancels shared work and waiting callers, but retains the current token.

Logout requires the app to cancel requests, discard the authenticator/client, and clear secure storage. Neither method revokes a server-side session.

## Retry and time

### `ReplayPolicy`

`.never`, `.idempotentMethods`, and `.allowed` govern both transient retries and replay after authentication refresh. `.allowed` is an explicit safety promise by the caller; it does not create server-side idempotency.

### `RetryPolicy`

Disabled by default. The initializer accepts a maximum retry count, base delay, maximum delay, and retryable status set. Counts must be 0–100; delays must be finite and nonnegative, with base delay no larger than the maximum and maximum no larger than 86,400 seconds.

Default retryable status codes are 408, 429, 500, 502, 503, and 504. Retryable URL errors are timed out, network connection lost, cannot connect to host, DNS lookup failed, and not connected to the internet. Other transport errors, including TLS failures, are not retried.

The policy uses full-jitter exponential backoff. Valid Retry-After seconds or HTTP dates take precedence. A server delay above the configured maximum prevents retry rather than shortening the server's delay. A 401 is reserved for the separate authentication path and is never treated as a transient status retry.

### `NetworkClock` and `SystemNetworkClock`

`now()` supplies wall-clock time for HTTP-date Retry-After interpretation. `sleep(for:)` waits between attempts and must honor cancellation. The system implementation uses Date and Task.sleep; tests can inject a virtual clock.

The injected random closure controls the full-jitter fraction. Out-of-range fractions are clamped to 0...1; non-finite values use the upper bound.

## Errors and observation

### `NetworkError`

| Category | Information |
|---|---|
| `invalidConfiguration`, `invalidPath`, `invalidHeader`, `insecureConnection` | Request/configuration validation failure |
| `invalidResponse` | A transport result was not an HTTP response |
| `missingAuthenticator`, `invalidCredential` | Missing authentication dependency or unusable credential |
| `authentication(underlying:)` | Credential acquisition or refresh failed |
| `transport(underlying:)` | Network execution failed |
| `http(_:)` | Response status was not accepted; preserves the full HTTPResponse |
| `decoding(underlying:response:)` | Response interpretation failed; preserves the cause and response |

These are diagnostic values, not localized UI text. Some validation errors can appear as an underlying authentication error when generated while obtaining credentials. Preserved bodies and causes may be sensitive.

### `NetworkObserver`, `NetworkEvent`, and `OSLogNetworkObserver`

An optional observer receives one event per logical request, including pre-transport failures. Events expose only correlation UUID, method, attempts, status if available, duration, and outcome. Duration includes execution/decoding before observation, not the observer's own latency.

Observers are awaited and should finish promptly. An event describes completion before observation; later caller cancellation still prevents value delivery without producing a second event. OSLog marks the correlation UUID private and does not receive error descriptions, URLs, headers, or payloads.

## Test-support product

`HTTPKitTestSupport` is a separate product for test targets:

- **`StubTransport`**: actor-isolated response/failure/async-handler steps, recorded requests, and explicit exhaustion errors.
- **`RecordingClock`**: virtual wall time and recorded sleeps without actual delay.
- **`RecordingObserver`**: actor-isolated completion events.

See [Testing](Testing.md) for complete examples. Feature-level tests should usually fake the app's service protocol rather than construct HTTP requests.
