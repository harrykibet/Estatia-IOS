import FirebaseAnalytics
import FirebasePerformance
import Foundation

/// Production event sink backed by Firebase Analytics.
///
/// Firebase Analytics owns its delivery queue and batches events for upload.
/// Event labels are normalized to Firebase's custom-event naming rules while
/// the original human-readable name remains available as `event_label`.
public final class FirebaseAnalyticsClient: AnalyticsClient {
    typealias EventLogger = (String, [String: Any]?) -> Void

    private let eventLogger: EventLogger

    public convenience init() {
        self.init { eventName, parameters in
            Analytics.logEvent(eventName, parameters: parameters)
        }
    }

    init(eventLogger: @escaping EventLogger) {
        self.eventLogger = eventLogger
    }

    public func track(name: String, properties: [String: String]) {
        let eventName = Self.normalizedEventName(for: name)
        var parameters: [String: Any] = [
            "event_label": String(name.prefix(100))
        ]

        // Firebase Analytics accepts at most 25 parameters per event. Reserve
        // one for the original label and apply a deterministic order to the rest.
        for (key, value) in properties.sorted(by: { $0.key < $1.key }) {
            let parameterName = Self.normalizedParameterName(for: key)
            guard parameterName != "event_label",
                  parameters[parameterName] == nil,
                  parameters.count < 25
            else {
                continue
            }

            parameters[parameterName] = String(value.prefix(100))
        }

        eventLogger(eventName, parameters)
    }

    static func normalizedEventName(for name: String) -> String {
        var result = normalizedName(name, maximumLength: 40)
        if result.hasPrefix("firebase_")
            || result.hasPrefix("google_")
            || result.hasPrefix("ga_") {
            result = "app_\(result)"
        }
        return String(result.prefix(40))
    }

    private static func normalizedParameterName(for name: String) -> String {
        var result = normalizedName(name, maximumLength: 40)
        if result.hasPrefix("firebase_")
            || result.hasPrefix("google_")
            || result.hasPrefix("ga_") {
            result = "meta_\(result)"
        }
        return String(result.prefix(40))
    }

    private static func normalizedName(
        _ value: String,
        maximumLength: Int
    ) -> String {
        let normalized = value
            .lowercased()
            .replacingOccurrences(
                of: "[^a-z0-9_]+",
                with: "_",
                options: .regularExpression
            )
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))

        let nonEmpty = normalized.isEmpty ? "event" : normalized
        let prefixed = nonEmpty.first?.isNumber == true
            ? "event_\(nonEmpty)"
            : nonEmpty
        return String(prefixed.prefix(maximumLength))
    }
}

/// Production QoS sink backed by Firebase Performance custom traces.
///
/// The measured duration is recorded as the `observed_duration_ms` custom
/// metric. The trace itself represents the short reporting operation; it does
/// not pretend that the already-completed playback interval is still running.
public final class FirebasePerformanceMetricsClient: MetricsClient {
    private static let excludedAttributeNames: Set<String> = [
        "media_id",
        "session_id",
        "user_id",
        "event_id",
        "email",
        "phone",
        "phone_number"
    ]

    public init() {}

    public func trackDuration(
        name: String,
        durationMilliseconds: Int64,
        tags: [String: String]
    ) {
        guard durationMilliseconds > 0,
              let trace = Performance.startTrace(
                name: Self.normalizedTraceName(for: name)
              )
        else {
            return
        }

        Self.safeAttributes(from: tags).forEach { key, value in
            trace.setValue(value, forAttribute: key)
        }
        trace.setValue(durationMilliseconds, forMetric: "observed_duration_ms")
        trace.stop()
    }

    public func incrementCounter(
        name: String,
        tags: [String: String]
    ) {
        guard let trace = Performance.startTrace(
            name: Self.normalizedTraceName(for: name)
        ) else {
            return
        }

        Self.safeAttributes(from: tags).forEach { key, value in
            trace.setValue(value, forAttribute: key)
        }
        trace.incrementMetric("count", by: 1)
        trace.stop()
    }

    static func normalizedTraceName(for name: String) -> String {
        let normalized = name
            .lowercased()
            .replacingOccurrences(
                of: "[^a-z0-9_]+",
                with: "_",
                options: .regularExpression
            )
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))

        let nonEmpty = normalized.isEmpty ? "app_metric" : normalized
        let prefixed = nonEmpty.first?.isNumber == true
            ? "app_\(nonEmpty)"
            : nonEmpty
        return String(prefixed.prefix(100))
    }

    /// Firebase Performance supports five custom attributes per trace. Avoid
    /// media/session/user identifiers: they create high-cardinality dimensions
    /// and are not needed to aggregate QoS by metric.
    static func safeAttributes(from tags: [String: String]) -> [String: String] {
        var attributes: [String: String] = [:]

        for (key, value) in tags.sorted(by: { $0.key < $1.key }) {
            let normalizedKey = key
                .lowercased()
                .replacingOccurrences(
                    of: "[^a-z_]+",
                    with: "_",
                    options: .regularExpression
                )
                .trimmingCharacters(in: CharacterSet(charactersIn: "_"))

            guard !normalizedKey.isEmpty,
                  !excludedAttributeNames.contains(normalizedKey),
                  !normalizedKey.hasPrefix("firebase_"),
                  !normalizedKey.hasPrefix("google_"),
                  !normalizedKey.hasPrefix("ga_"),
                  attributes[normalizedKey] == nil,
                  attributes.count < 5
            else {
                continue
            }

            attributes[String(normalizedKey.prefix(32))] = String(value.prefix(100))
        }

        return attributes
    }
}
