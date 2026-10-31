import Foundation

public protocol NetworkClock: Sendable {
    /// Supplies wall-clock time for HTTP-date Retry-After interpretation.
    func now() async -> Date
    /// Suspends between attempts and must honor task cancellation.
    func sleep(for duration: Duration) async throws
}

public struct SystemNetworkClock: NetworkClock {
    public init() {}
    public func now() async -> Date { Date() }
    public func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

public struct RetryPolicy: Sendable {
    public private(set) var maximumRetries: Int = 0
    public private(set) var baseDelay: TimeInterval = 0.5
    public private(set) var maximumDelay: TimeInterval = 30
    public private(set) var statusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]

    public static let none = RetryPolicy()

    private init() {}

    /// Limits apply to retries in addition to the initial attempt. Authentication replay is separate.
    public init(
        maximumRetries: Int,
        baseDelay: TimeInterval = 0.5,
        maximumDelay: TimeInterval = 30,
        statusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]
    ) throws {
        guard (0...100).contains(maximumRetries), baseDelay.isFinite, baseDelay >= 0,
              maximumDelay.isFinite, maximumDelay >= baseDelay, maximumDelay <= 86_400 else {
            throw NetworkError.invalidConfiguration
        }
        self.maximumRetries = maximumRetries
        self.baseDelay = baseDelay
        self.maximumDelay = maximumDelay
        self.statusCodes = statusCodes
    }

    func retries(_ error: any Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                .dnsLookupFailed, .notConnectedToInternet].contains(urlError.code)
    }

    /// Full jitter. A Retry-After exceeding the allowed wait causes failure, never an early retry.
    func delay(retry: Int, response: HTTPResponse?, now: Date, random: Double) -> Duration? {
        if let header = response?.headers["Retry-After"], let serverDelay = Self.retryAfter(header, now: now) {
            guard serverDelay <= maximumDelay else { return nil }
            return .seconds(serverDelay)
        }
        let cap = min(maximumDelay, baseDelay * pow(2, Double(min(retry, 60))))
        let fraction = random.isFinite ? min(1, max(0, random)) : 1
        return .seconds(cap * fraction)
    }

    private static func retryAfter(_ value: String, now: Date) -> TimeInterval? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) {
            // Overflow still means "wait longer than our budget", not "ignore the server".
            return Double(value) ?? .infinity
        }
        // HTTP wire format is fixed English/GMT, not the device's locale or timezone.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}
