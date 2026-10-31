import Foundation

/// An opaque credential revision: identical token text after refresh is still a new revision.
public struct HTTPAuthorization: Sendable, Equatable {
    public let headerValue: String
    private let revision = UUID()

    public init(headerValue: String) { self.headerValue = headerValue }
}

public protocol RequestAuthenticator: Sendable {
    /// Returns the current credential, preserving its revision while the credential is unchanged.
    func authorization() async throws -> HTTPAuthorization
    /// Handles rejection of a specific credential revision, ignoring stale rejections when appropriate.
    func refresh(after rejected: HTTPAuthorization) async throws
}

/// Single-flight token refresh with independently cancellable waiters.
/// The app owns secure persistence and the unauthenticated refresh HTTP call.
public actor BearerTokenAuthenticator: RequestAuthenticator {
    private var current: HTTPAuthorization
    private let refreshToken: @Sendable () async throws -> String
    private var flight: (id: UUID, task: Task<Void, Never>)?
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    /// Creates a bearer authenticator without persisting credentials.
    /// The refresh closure must use an independent client and manage secure token rotation itself.
    public init(accessToken: String, refresh: @escaping @Sendable () async throws -> String) throws {
        current = try Self.credential(accessToken)
        refreshToken = refresh
    }

    public func authorization() async throws -> HTTPAuthorization {
        try Task.checkCancellation()
        return current
    }

    public func refresh(after rejected: HTTPAuthorization) async throws {
        try Task.checkCancellation()
        // A late 401 for an older credential must not refresh the new credential again.
        guard current == rejected else { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[waiterID] = continuation
                if flight == nil {
                    let flightID = UUID()
                    let refresh = refreshToken
                    // Shared work has a lifetime owned by this actor, not by the first requester.
                    let task = Task {
                        let result: Result<HTTPAuthorization, any Error>
                        do { result = .success(try Self.credential(try await refresh())) }
                        catch { result = .failure(error) }
                        self.complete(flightID, result: result)
                    }
                    flight = (flightID, task)
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    /// Use on account/token change. Cancels refresh and prevents late results restoring old credentials.
    public func replaceAccessToken(_ token: String) throws {
        let replacement = try Self.credential(token)
        cancelRefresh()
        current = replacement
    }

    /// Cancels all waiters. Discard this authenticator on logout; it does not erase app-owned storage.
    public func cancelRefresh() {
        flight?.task.cancel()
        flight = nil
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending { waiter.resume(throwing: CancellationError()) }
    }

    private func complete(_ id: UUID, result: Result<HTTPAuthorization, any Error>) {
        guard flight?.id == id else { return }
        flight = nil
        let pending = waiters.values
        waiters.removeAll()
        switch result {
        case .success(let credential):
            current = credential
            for waiter in pending { waiter.resume() }
        case .failure(let error):
            for waiter in pending { waiter.resume(throwing: error) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        if waiters.isEmpty {
            flight?.task.cancel()
            flight = nil
        }
    }

    private static func credential(_ token: String) throws -> HTTPAuthorization {
        guard !token.isEmpty, token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            throw NetworkError.invalidCredential
        }
        return HTTPAuthorization(headerValue: "Bearer " + token)
    }
}
