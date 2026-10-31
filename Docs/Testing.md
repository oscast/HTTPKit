# Testing

## Run the suite

```sh
swift test
swift test -c release
bash Scripts/test-ios.sh 18
bash Scripts/test-ios.sh 26
```

The simulator script selects an available iPhone for the requested iOS major version. Missing runtimes cause an explicit failure, never a silent platform skip. The script respects `DEVELOPER_DIR` without changing global xcode-select settings. Logs and result bundles are stored in `TestResults/`; build artifacts are stored in `.build/`.

## Use the test support in another app

Add HTTPKitTestSupport to the test target only:

```swift
import Foundation
import Testing
import HTTPKit
import HTTPKitTestSupport

@Test func loadsBinaryData() async throws {
    let transport = StubTransport([
        .response(HTTPResponse(statusCode: 200, body: Data([1, 2, 3])))
    ])
    let url = try #require(URL(string: "https://example.com"))
    let client = HTTPClient(configuration: .init(baseURL: url), transport: transport)
    let data = try await client.send(Endpoint<Data>(path: ["file"], decoder: .data))
    #expect(data == Data([1, 2, 3]))
    #expect(await transport.requests.count == 1)
}
```

`StubTransport.Step` supports `.response`, `.failure`, and async `.handler` cases. Each instance consumes a step before executing its handler, preventing reentrancy from reusing the same response. Exhausted stubs throw `StubError.exhausted` instead of reaching the network.

`RecordingClock` records delays and advances virtual wall time without sleeping. Inject `random: { 1 }` to test the backoff upper bound, or a known fraction to test jitter. `RecordingObserver` stores completion events, not complete requests.

For ViewModel tests, inject an app-owned service protocol (`UsersServing` in the example). You do not need to mock URLSession in every UI or business-logic test.

## Coverage by boundary

- **RequestBuilder:** path encoding, reserved characters, repeated query items, case-insensitive headers, JSON bodies, timeout, HTTP opt-in, invalid inputs, and injection prevention.
- **HTTPClient:** status/metadata, configurable JSON, binary/empty/custom decoding, original errors, compiled service examples, cancellation, observation, and concurrent decoding.
- **Retry:** budgets, safe/unsafe methods, opt-in, backoff/jitter/caps, Retry-After, TLS exclusion, and cancellation during a wait.
- **Authentication:** one allowed replay, failures, single-flight behavior, stale revisions, concurrent callers, cancellation/replacement during refresh, public endpoints, invalid tokens, and custom-authenticator header validation.
- **URLSessionTransport:** a real session intercepted by a stateless URLProtocol fixture; data/headers, transport failures, and non-HTTP responses. Redirect policy tests invoke the delegate directly; they do not simulate a real TLS redirect chain.

No unit test depends on public servers or credentials. URLProtocol fixtures have no shared mutable global handlers: behavior is fixed by route, allowing parallel execution. Gates and continuations coordinate tasks. The 60-second sleeps only simulate suspended cancellable operations; they do not wait for a race to "settle."

## CI template and activation

[CI.workflow.yml](CI.workflow.yml) contains the intended workflow. It is published as a template, not as an active Actions workflow, because the publishing credential lacks the `workflow` authorization scope. The local `.github/workflows/ci.yml` remains available but is not part of the published Git tree.

To enable automatic checks, an authorized repository owner can place the template at `.github/workflows/ci.yml` and commit it with a credential permitted to manage workflows. No account permission was changed automatically.

- macOS 15 + Xcode 16.0: `swift test` with Swift 6.0 to check the declared minimum compiler.
- macOS 15 + Xcode 16.4: iOS 18 simulator.
- macOS 26 + Xcode 26.4.1: iOS 26 simulator.
- Swift Release build in the iOS matrix.

Runner tools and runtimes change over time. The selection is based on the [macOS 15 image](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md) and [macOS 26 image](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md). If an image removes a tool, update the matrix explicitly rather than turning the failure into a skip.

The template has not run on GitHub. Automatic CI activation is pending. [Validation](Validation.md) records only checks actually performed.
