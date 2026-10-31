# Security boundaries

## Threat model

- **Assets:** access/refresh tokens, personal data, HTTP payloads, and account credentials.
- **Boundaries:** trusted app configuration → endpoint → untrusted network → API. Responses and redirects remain untrusted input.
- **Threats:** interception, HTTP downgrade, header injection, cross-origin credential forwarding, private data in logs, unsafe replay, and stale refresh results restoring an old session.

## Package mitigations

- HTTPS by default and standard URLSession TLS validation. No delegate accepts invalid certificates.
- Base URLs cannot contain usernames, passwords, or fragments. Relative path segments are encoded independently; user-provided absolute URLs are not interpolated into routes.
- Header names and values are validated against invalid names, control characters, and CR/LF injection before constructing a request. Authorization returned by custom authenticators is validated too.
- Redirects must preserve scheme, hostname, and effective port, and cannot embed URL credentials. A rejected redirect remains a 3xx response for the caller instead of being followed.
- Replay can be disabled entirely. POST/PATCH are not replayed by default, including after token refresh.
- Opaque credential revisions and refresh-flight identifiers invalidate stale work.
- Completion events contain no URLs, headers, bodies, credentials, or error descriptions. OSLog correlation UUIDs are private; observation is opt-in.

## Application responsibilities

- Obtain credentials from your backend and store them in Keychain with appropriate accessibility and access groups. Never put API secrets in source code, bundles, UserDefaults, or repositories. HTTPKit does not persist credentials.
- Enforce authorization on the server. Client-side checks are not authorization.
- Persist rotated refresh tokens and handle revocation inside your app's refresh flow. Use a separate client and bounded timeout; avoid retention or request cycles.
- On logout, cancel active tasks and refresh, discard clients/authenticators, and clear credential storage/cookies as appropriate. Cancelling refresh does not revoke credentials by itself.
- Configure cookies, caches, and sessions for your backend. An injected session may attach credentials independently of HTTPKit's authenticator.
- Bound concurrency and response sizes for real workloads. This transport buffers Data in memory: it is not a large-file downloader and does not enforce a hard memory limit.
- Do not accept arbitrary route/header configuration from untrusted input. Keep host configuration under app control.
- Do not log a complete NetworkError: it preserves original data for private diagnostics.
- Do not add ATS exceptions or certificate pinning without a threat model and a viable rotation/recovery strategy.
- If you replace HTTPTransport, preserve TLS, redirect, and cancellation guarantees in that implementation. HTTPKit cannot enforce its default adapter's behavior on external transports.

No entitlements, permissions, or PrivacyInfo.xcprivacy declarations have been invented or added. Each consuming app must review its actual data usage, SDK dependencies, and privacy obligations.
