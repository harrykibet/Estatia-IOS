import Foundation
import Testing
import CoreModel
@testable import CoreNetwork

@Test func authRestRemoteDataSourceSignIn() async throws {
    let expected = User(
        userId: "user-1",
        name: "Ada",
        email: "ada@example.com",
        verified: true
    )
    let responseData = try JSONEncoder().encode(expected)
    let client = StubAPIClient(responseData: responseData)
    let dataSource = AuthRestRemoteDataSource(client: client)

    let result = try await dataSource.signIn(
        email: "ada@example.com",
        password: "secret"
    )

    let request = await client.recordedRequest()
    #expect(request?.method == "POST")
    #expect(request?.path == "/auth/signin")
    #expect(result.user == expected)
    #expect(result.status == .authenticated)
}

@Test func authRestRemoteDataSourceSignUpReturnsPendingEmailVerification() async throws {
    let expected = User(
        userId: "user-2",
        name: "Ada",
        email: "ada@example.com",
        verified: false
    )
    let responseData = try JSONEncoder().encode(expected)
    let client = StubAPIClient(responseData: responseData)
    let dataSource = AuthRestRemoteDataSource(client: client)

    let result = try await dataSource.signUp(
        email: "ada@example.com",
        password: "secret",
        displayName: "Ada"
    )

    let request = await client.recordedRequest()
    #expect(request?.method == "POST")
    #expect(request?.path == "/auth/signup")
    #expect(result.user == expected)
    #expect(result.status == .pendingVerification(.email))
}

@Test func authRestRemoteDataSourceCurrentSessionReturnsUnauthenticatedForEmptyResponse() async throws {
    let client = StubAPIClient(responseData: Data())
    let dataSource = AuthRestRemoteDataSource(client: client)

    let result = try await dataSource.currentSession()

    let request = await client.recordedRequest()
    #expect(request?.method == "GET")
    #expect(request?.path == "/auth/me")
    #expect(result == .unauthenticated)
}

@Test func authRestRemoteDataSourceCurrentSessionDecodesVerifiedUser() async throws {
    let expected = User(
        userId: "user-3",
        name: "Ada",
        email: "ada@example.com",
        verified: true
    )
    let client = StubAPIClient(responseData: try JSONEncoder().encode(expected))
    let dataSource = AuthRestRemoteDataSource(client: client)

    let result = try await dataSource.currentSession()

    #expect(result.user == expected)
    #expect(result.status == .authenticated)
}

@Test func propertyRestRemoteDataSourceSearchBuildsQuery() async throws {
    let responseData = try JSONEncoder().encode([PropertyModel()])
    let client = StubAPIClient(responseData: responseData)
    let dataSource = PropertyRestRemoteDataSource(client: client)
    let filters = PropertySearchFilters(
        minPrice: 1000,
        maxPrice: 2000,
        county: "King",
        availableOnly: true
    )

    _ = try await dataSource.searchProperties(query: "loft", filters: filters)

    let request = await client.recordedRequest()
    #expect(request?.method == "GET")
    #expect(request?.path == "/properties/search")
    #expect(request?.query?.contains(where: { $0.name == "q" && $0.value == "loft" }) == true)
    #expect(request?.query?.contains(where: { $0.name == "minPrice" && $0.value == "1000.0" }) == true)
    #expect(request?.query?.contains(where: { $0.name == "county" && $0.value == "King" }) == true)
    #expect(request?.query?.contains(where: { $0.name == "availableOnly" && $0.value == "true" }) == true)
}

@Test func userRestRemoteDataSourceAddsFavorite() async throws {
    let client = StubAPIClient(responseData: Data())
    let dataSource = UserRestRemoteDataSource(client: client)

    try await dataSource.addFavoriteProperty(userId: "user-1", propertyId: "prop-9")

    let request = await client.recordedRequest()
    #expect(request?.method == "POST")
    #expect(request?.path == "/users/user-1/favorites")
    let payload = try JSONDecoder().decode(FavoriteBody.self, from: request?.body ?? Data())
    #expect(payload.propertyId == "prop-9")
}

private struct RecordedRequest: Sendable {
    let method: String
    let path: String
    let query: [URLQueryItem]?
    let body: Data?
}

actor StubAPIClient: APIClient {
    private let responseData: Data
    private var request: RecordedRequest?

    init(responseData: Data) {
        self.responseData = responseData
    }

    fileprivate func recordedRequest() -> RecordedRequest? {
        request
    }

    func get(_ path: String, query: [URLQueryItem]?) async throws -> Data {
        record(method: "GET", path: path, query: query, body: nil)
        return responseData
    }

    func post(_ path: String, body: Data?) async throws -> Data {
        record(method: "POST", path: path, query: nil, body: body)
        return responseData
    }

    func put(_ path: String, body: Data?) async throws -> Data {
        record(method: "PUT", path: path, query: nil, body: body)
        return responseData
    }

    func delete(_ path: String) async throws -> Data {
        record(method: "DELETE", path: path, query: nil, body: nil)
        return responseData
    }

    private func record(
        method: String,
        path: String,
        query: [URLQueryItem]?,
        body: Data?
    ) {
        request = RecordedRequest(
            method: method,
            path: path,
            query: query,
            body: body
        )
    }
}

private struct FavoriteBody: Codable {
    let propertyId: String
}
