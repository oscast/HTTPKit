import Foundation
import OSLog

/// Deliberately contains no URL, path, query, headers, body, credentials or error descriptions.
public struct NetworkEvent: Sendable {
    public enum Outcome: String, Sendable {
        case success, failure, cancelled
    }

    public let requestID: UUID
    public let method: HTTPMethod
    public let attempts: Int
    public let statusCode: Int?
    public let duration: Duration
    public let outcome: Outcome
}

public protocol NetworkObserver: Sendable {
    /// Called once per logical request, including failures before transport execution.
    /// Describes completion before observation; late caller cancellation can still prevent delivery.
    func record(_ event: NetworkEvent) async
}

public struct OSLogNetworkObserver: NetworkObserver {
    private let logger: Logger

    public init(subsystem: String, category: String = "HTTPKit") {
        logger = Logger(subsystem: subsystem, category: category)
    }

    public func record(_ event: NetworkEvent) async {
        logger.debug("HTTP \(event.method.rawValue, privacy: .public) outcome=\(event.outcome.rawValue, privacy: .public) status=\(event.statusCode ?? 0) attempts=\(event.attempts) duration=\(String(describing: event.duration), privacy: .public) id=\(event.requestID.uuidString, privacy: .private)")
    }
}
