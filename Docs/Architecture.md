# Architecture and pattern decisions

## Forces and boundaries

Each app owns its backend configuration, routes, DTOs, authentication rules, and domain error mapping. Tests replace network transport, time, and credentials with deterministic implementations. The stable contract is HTTP—not any particular API's business domain.

```text
Feature → App-owned service protocol / implementation
                       ↓
                 Endpoint<Response>
                       ↓
                   HTTPClient
     RequestBuilder → optional auth/retry → HTTPTransport
                       ↓                         ↓
               validation/decoder          URLSessionTransport
                       ↓
           DecodedResponse<Response> / Error
```

## Decisions

| Concern | Choice and reason | Rejected alternative |
|---|---|---|
| Distribution | One Swift package for iOS 18+ and macOS 15+ | Duplicate implementations for each iOS release |
| Dependencies | Foundation, Swift Concurrency, OSLog | An external HTTP framework without a concrete need |
| Typed API | Generic endpoints and Sendable decoders | Returning Any and casting in services |
| Protocols | Transport, authentication, clock, and observer boundaries | Protocols for every concrete type |
| Business logic | App-owned services and service protocols | A universal Repository or BaseService |
| Shared state | Immutable client; actors for authentication and test doubles | Global singletons, application locks, or serializing all requests through one client actor |
| Composition | Explicit optional policies in the initializer | An open-ended interceptor or middleware framework |
| Swift | Tools version 6.0, language mode 6, no default MainActor | Tying language features to an iOS version or silencing isolation errors with unsafe annotations |
| URLSession | Ephemeral session by default; session injection supported | Mandatory shared global session state |
| Diagnostics | A small privacy-safe completion event | Logging complete requests and responses |

## Concurrency and ownership

- `HTTPClient`, endpoints, and responses are `Sendable`. They have no UI framework or MainActor dependency.
- The package keeps Swift 6.0 isolation semantics. It does not enable `NonisolatedNonsendingByDefault` or default MainActor isolation; the consuming app can configure its own module independently.
- `async` is not a guarantee of a particular CPU thread. The implementation does not use `Task.detached` or custom DispatchQueue hops.
- Each JSONEncoder/JSONDecoder is created locally. DTOs crossing concurrency boundaries must be Sendable.
- Production code has no `@unchecked Sendable`. A stateless URLProtocol test fixture restates Foundation's inherited unchecked conformance.
- The caller owns the request task. Cancelling it reaches transport execution and backoff waits.
- The authenticator actor owns one unstructured refresh task so shared work can outlive a single cancelled requester. It cancels that task when no waiters remain, the token is replaced, or `cancelRefresh` is called.
- A flight identifier prevents a late refresh task from overwriting newer credentials. An opaque authorization revision distinguishes even identical token strings returned by successive refreshes.
- Refresh callbacks should be bounded, cancellation-aware, and independent of the authenticator. Avoid capturing it or creating a dependency cycle. The client retains its authenticator, clock, transport, and observer.
- The caller owns an injected session's lifecycle. HTTPKit does not invalidate it.

## Request and response policies

The default accepted status range is `200..<300`. An endpoint can override it. Bodies are ignored only when the endpoint explicitly selects `.empty`; invalid JSON is not treated as an empty success.

HTTP failure bodies are not decoded into a success DTO. Applications map backend error payloads from the preserved response metadata.

`HTTPHeaders` lowercases field names and stores one value per name. It is not a raw HTTP parser: Foundation combines response fields. Do not use it as a cookie store or assume it preserves separate Set-Cookie fields.

A retry budget spans the logical request, including attempts before and after the single allowed authentication replay. Authentication replay is separate from the transient retry count. Both are gated by the endpoint's replay policy.

## Risks and verification

Primary risks are unsafe replay, credential disclosure, refresh races, and lost cancellation. Tests exercise replay policies, URL and header construction, redirects, stale credentials, refresh replacement/cancellation, real URLSession behavior through URLProtocol, and two iOS simulator runtimes.

These tests do not validate production certificates, backend token rotation, server-side authorization, or physical network behavior. Each app needs integration tests for those contracts.

## Migration and rollback

HTTPKit is a new package and does not modify an existing app. To adopt it, keep the old implementation behind your feature's service protocol, add characterization tests, and switch the injected implementation. Rolling back the injection restores the previous service without a data migration. Do not move business rules into HTTPKit during adoption.

## Evolution

Before a 1.0.0 release, validate integration in a real app, select a license, and review the public API. After 1.0, use major versions for incompatible changes, minor versions for additive capabilities, and patch versions for compatible fixes. Design streaming, file/background transfers, and offline behavior separately when a concrete requirement exists.
