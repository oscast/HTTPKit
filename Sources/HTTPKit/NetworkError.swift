import Foundation

/// Diagnostic errors, not user-facing copy. Bodies and underlying errors may contain sensitive data.
public enum NetworkError: Error {
    case invalidConfiguration
    case invalidPath
    case invalidHeader
    case insecureConnection
    case invalidResponse
    case missingAuthenticator
    case invalidCredential
    case authentication(underlying: any Error)
    case transport(underlying: any Error)
    case http(HTTPResponse)
    case decoding(underlying: any Error, response: HTTPResponse)
}
