import Foundation

/// Receives playback performance durations and counters independently from
/// user-facing analytics events.
public protocol MetricsClient {
    func trackDuration(
        name: String,
        durationMilliseconds: Int64,
        tags: [String: String]
    )

    func incrementCounter(
        name: String,
        tags: [String: String]
    )
}

/// Safe default for clients that do not configure a metrics backend.
public final class NoopMetricsClient: MetricsClient {
    public init() {}

    public func trackDuration(
        name: String,
        durationMilliseconds: Int64,
        tags: [String: String]
    ) {}

    public func incrementCounter(
        name: String,
        tags: [String: String]
    ) {}
}
