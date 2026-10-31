# Validation record

Local validation performed on **October 30, 2026**. These results do not certify an application's backend or represent a published release.

## Executed checks

| Gate | Environment | Result |
|---|---|---|
| `swift test -Xswiftc -warnings-as-errors` | Xcode 27 / Swift 6.4, macOS | 51 tests in 5 suites passed |
| `swift test -c release` | Xcode 27 / Swift 6.4, macOS | 51 tests in 5 suites passed |
| 10 additional `swift test --skip-build` runs | macOS, parallel tests | 10/10 runs passed, 51 tests each |
| `bash Scripts/test-ios.sh 18` | iPhone 16 Pro, iOS 18.6, Xcode 27 | 51 tests in 5 suites passed |
| `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer bash Scripts/test-ios.sh 26` | iPhone 17 Pro, iOS 26.5, Xcode 26.6 / Swift 6.3.3 | 51 tests in 5 suites passed |
| Publication README and testing-guide examples | Independent local SPM consumer, Swift 6 mode | All app/test examples compiled; both documentation tests passed |
| Publication installation manifest fragments | `swift package dump-package` | Parsed successfully without fetching the proposed remote repository |
| Documentation language and local links | README, five guides, source comments | English reviewed; all relative documentation links resolve |
| `bash -n Scripts/test-ios.sh` | bash | Passed |
| CI YAML parsing | PyYAML | Passed |
| Public SPM dependency, exact `0.1.0` | Independent consumer fetched from GitHub and built the tagged package | Both README/testing-guide integration tests passed |
| Anonymous Git tag lookup | Credential helpers disabled | Public `0.1.0` tag resolves to `8cb38cc68edbe3e637790da119b5e586a17d3f63` |
| GitHub license detection | Repository license API | MIT recognized |
| Provider-independence audit | Sources, Examples, and Tests | No provider-specific references or types |
| Concurrency annotation audit | Sources | No unchecked Sendable, preconcurrency, nonisolated(unsafe), or Task.detached |

## Local evidence

The simulator script writes a unique folder per run under `TestResults/` (ignored by Git):

- `iOS18.Lvf0vh/Results.xcresult`
- `iOS26.xfTamb/Results.xcresult`

Each folder contains its xcodebuild log and simulator inventory. Xcode emits an App Intents metadata-extraction notice because this package does not depend on App Intents. There were no compiler errors or test failures.

These are machine-local artifacts, not files included in the public package. Regenerate them with the simulator script on your own machine.

## Published package verification

The public repository is [oscast/HTTPKit](https://github.com/oscast/HTTPKit), with release [0.1.0](https://github.com/oscast/HTTPKit/releases/tag/0.1.0). A separate Swift package resolved the exact version from that remote URL rather than using a local path dependency. Its Package.resolved pinned the commit above, and both documentation integration tests passed.

The license is MIT, copyright (c) 2026 Oscar Castillo. GitHub recognizes the license. No provider-specific integration was added. Automatic Actions execution remains pending as described below.

## Pending or outside this validation

- Run the **Swift 6.0 / Xcode 16.0** CI job before guaranteeing that compiler minimum. It is declared and configured, but that Xcode version is not installed locally.
- Activate the published CI template with a credential authorized to manage GitHub workflows, then run it. The current publishing credential lacks the `workflow` scope; automatic CI is not active. A template is not evidence of a successful run.
- Physical devices, exact iOS 18.0 availability, real-server TLS/redirects, degraded networks, and a production backend.
- Thread Sanitizer, measured load/resource usage, and very large payloads. Concurrent tests do not replace those checks.
- Integration into a real app. The initial public version is tagged `0.1.0`.

HTTPKit is a functional foundation verified in the environments listed above—not a promise of every HTTP capability or of safety guarantees for arbitrary external protocol implementations.
