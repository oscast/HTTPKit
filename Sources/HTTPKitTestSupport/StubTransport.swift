import Foundation
import HTTPKit

/// An instance-scoped, parallel-safe transport. Missing stubs fail instead of reaching the network.
public actor StubTransport: HTTPTransport {
    public enum StubError: Error { case exhausted }
    public enum Step: Sendable {
        case response(HTTPResponse)
        case failure(any Error)
        case handler(@Sendable (URLRequest) async throws -> HTTPResponse)
    }

    private var steps: [Step]
    public private(set) var requests: [URLRequest] = []

    public init(_ steps: [Step]) { self.steps = steps }

    public func execute(_ request: URLRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()
        requests.append(request)
        guard !steps.isEmpty else { throw StubError.exhausted }
        let step = steps.removeFirst()
        switch step {
        case .response(let response): return response
        case .failure(let error): throw error
        case .handler(let handler): return try await handler(request)
        }
    }
}

/// Records requested delays and advances virtual wall time without sleeping.
public actor RecordingClock: NetworkClock {
    private var date: Date
    public private(set) var sleeps: [Duration] = []

    public init(now: Date = Date(timeIntervalSince1970: 0)) { date = now }
    public func now() -> Date { date }
    public func sleep(for duration: Duration) throws {
        try Task.checkCancellation()
        sleeps.append(duration)
        let parts = duration.components
        date.addTimeInterval(Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
    }
}

public actor RecordingObserver: NetworkObserver {
    public private(set) var events: [NetworkEvent] = []
    public init() {}
    public func record(_ event: NetworkEvent) { events.append(event) }
}
