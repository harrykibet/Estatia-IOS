import Testing
@testable import CoreAnalytics

@Test func firebaseAnalyticsClientMapsPlaybackEventsToValidEventNames() {
    var recordedEvent: (name: String, parameters: [String: Any]?)?
    let client = FirebaseAnalyticsClient { name, parameters in
        recordedEvent = (name, parameters)
    }

    client.track(
        name: "Personalized content engagement",
        properties: [
            "media_id": "media-123",
            "watch_time_ms": "12500",
            "loop_count": "2",
            "signal_type": "WATCH"
        ]
    )

    #expect(recordedEvent?.name == "personalized_content_engagement")
    #expect(recordedEvent?.parameters?["event_label"] as? String == "Personalized content engagement")
    #expect(recordedEvent?.parameters?["media_id"] as? String == "media-123")
    #expect(recordedEvent?.parameters?["watch_time_ms"] as? String == "12500")
    #expect(recordedEvent?.parameters?["signal_type"] as? String == "WATCH")
}

@Test func firebaseAnalyticsClientBoundsParametersAndNormalizesReservedPrefixes() {
    var recordedParameters: [String: Any]?
    let client = FirebaseAnalyticsClient { _, parameters in
        recordedParameters = parameters
    }
    let properties = Dictionary(
        uniqueKeysWithValues: (0..<40).map { ("key_\($0)", "value") }
    ).merging(["firebase_internal": "reserved"]) { current, _ in current }

    client.track(name: "123 unusual / event", properties: properties)

    #expect(recordedParameters?.count == 25)
    #expect(recordedParameters?["meta_firebase_internal"] as? String == nil
        || recordedParameters?["meta_firebase_internal"] as? String == "value")
    #expect(FirebaseAnalyticsClient.normalizedEventName(for: "123 unusual / event").hasPrefix("event_"))
}

@Test func firebasePerformanceMetricsAvoidHighCardinalityIdentifiers() {
    let attributes = FirebasePerformanceMetricsClient.safeAttributes(
        from: [
            "media_id": "media-123",
            "session_id": "session-456",
            "signal_type": "WATCH",
            "loop_index": "2",
            "content_type": "on_demand"
        ]
    )

    #expect(attributes["media_id"] == nil)
    #expect(attributes["session_id"] == nil)
    #expect(attributes["signal_type"] == "WATCH")
    #expect(attributes["content_type"] == "on_demand")
}

@Test func firebasePerformanceMetricsNormalizeTraceNames() {
    #expect(
        FirebasePerformanceMetricsClient.normalizedTraceName(for: "player.startup.duration")
            == "player_startup_duration"
    )
}
