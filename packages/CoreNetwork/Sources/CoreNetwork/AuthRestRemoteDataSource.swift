import Foundation
import CoreModel

public final class AuthRestRemoteDataSource: AuthRemoteDataSource {
    private let client: APIClient
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(
        client: APIClient,
        decoder: JSONDecoder = JSONDecoder(),
        encoder: JSONEncoder = JSONEncoder()
    ) {
        self.client = client
        self.decoder = decoder
        self.encoder = encoder
    }

    public func signIn(
        email: String,
        password: String
    ) async throws -> AuthSession {
        let payload = AuthCredentials(email: email, password: password)
        let data = try await client.post(
            "/auth/signin",
            body: try encoder.encode(payload)
        )
        let user = try decoder.decode(User.self, from: data)
        return makeSession(for: user)
    }

    public func signUp(
        email: String,
        password: String,
        displayName: String?
    ) async throws -> AuthSession {
        let payload = SignUpPayload(
            email: email,
            password: password,
            displayName: displayName
        )
        let data = try await client.post(
            "/auth/signup",
            body: try encoder.encode(payload)
        )
        let user = try decoder.decode(User.self, from: data)
        return makeSession(for: user)
    }

    public func signOut() async throws {
        _ = try await client.post("/auth/signout", body: nil)
    }

    public func currentSession() async throws -> AuthSession {
        let data = try await client.get("/auth/me")
        guard !data.isEmpty else {
            return .unauthenticated
        }

        let user = try decoder.decode(User.self, from: data)
        return makeSession(for: user)
    }

    private func makeSession(for user: User) -> AuthSession {
        let status: AuthStatus = user.verified
            ? .authenticated
            : .pendingVerification(.email)

        return AuthSession(user: user, status: status)
    }
}

private struct AuthCredentials: Codable {
    let email: String
    let password: String
}

private struct SignUpPayload: Codable {
    let email: String
    let password: String
    let displayName: String?
}
