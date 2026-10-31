import Foundation
import HTTPKit

public struct User: Codable, Sendable, Equatable {
    public let id: Int
    public let name: String

    public init(id: Int, name: String) { self.id = id; self.name = name }
}

/// The feature's testing boundary belongs to the app, not to the generic network package.
public protocol UsersServing: Sendable {
    func users() async throws -> [User]
    func currentUser() async throws -> User
}

public struct UsersService: UsersServing {
    private let client: HTTPClient

    public init(client: HTTPClient) { self.client = client }

    public func users() async throws -> [User] {
        try await client.send(Endpoint<[User]>.json(path: ["users"]))
    }

    public func currentUser() async throws -> User {
        try await client.send(Endpoint<User>.json(path: ["me"], requiresAuthentication: true))
    }

    public func deleteUser(id: Int) async throws {
        _ = try await client.send(Endpoint<EmptyResponse>(
            path: ["users", String(id)], method: .delete,
            requiresAuthentication: true, decoder: .empty
        ))
    }
}
