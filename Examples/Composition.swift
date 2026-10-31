import Foundation
import HTTPKit

/// Call once in the app's composition root. Supply the API URL from app configuration.
public func makePublicUsersService(baseURL: URL) -> UsersService {
    UsersService(client: HTTPClient(configuration: .init(baseURL: baseURL)))
}

/// Load the initial token from the app's secure storage, not from source code or UserDefaults.
/// The refresh closure must use a separate unauthenticated client and persist rotated tokens.
public func makeAuthenticatedUsersService(
    baseURL: URL,
    accessToken: String,
    refreshAccessToken: @escaping @Sendable () async throws -> String
) throws -> (service: UsersService, authenticator: BearerTokenAuthenticator) {
    let authenticator = try BearerTokenAuthenticator(accessToken: accessToken, refresh: refreshAccessToken)
    let client = HTTPClient(
        configuration: .init(baseURL: baseURL),
        authenticator: authenticator,
        retryPolicy: try RetryPolicy(maximumRetries: 2)
    )
    return (UsersService(client: client), authenticator)
}
