import Foundation

public struct Cdn: @unchecked Sendable {
    /// Default CDN endpoints mirrored from Android's bundled network configuration.
    public static let estatiaDefaults: [Cdn] = [
        Cdn(id: "primary", baseURL: URL(string: "https://primarycdn.estatia.com")!),
        Cdn(id: "backup", baseURL: URL(string: "https://backupcdn.estatia.com")!)
    ]
    public let id: String
    public let baseURL: URL
    public let healthCheckPath: String?

    public init(id: String, baseURL: URL, healthCheckPath: String? = nil) {
        self.id = id
        self.baseURL = baseURL
        self.healthCheckPath = healthCheckPath
    }

    public func resolve(path: String) -> URL {
        return URL(string: path, relativeTo: baseURL) ?? baseURL
    }
}
