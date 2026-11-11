import CoreAnalytics
import XCTest
@testable import CorePlayerEngine

private final class RecordingAnalyticsClient: AnalyticsClient {
    struct Event {
        let name: String
        let properties: [String: String]
    }

    private(set) var events: [Event] = []

    func track(name: String, properties: [String: String]) {
        events.append(Event(name: name, properties: properties))
    }
}

private final class RecordingMetricsClient: MetricsClient {
    struct Duration {
        let name: String
        let milliseconds: Int64
        let tags: [String: String]
    }

    struct Counter {
        let name: String
        let tags: [String: String]
    }

    private(set) var durations: [Duration] = []
    private(set) var counters: [Counter] = []

    func trackDuration(
        name: String,
        durationMilliseconds: Int64,
        tags: [String: String]
    ) {
        durations.append(
            Duration(
                name: name,
                milliseconds: durationMilliseconds,
                tags: tags
            )
        )
    }

    func incrementCounter(name: String, tags: [String: String]) {
        counters.append(Counter(name: name, tags: tags))
    }
}

@MainActor
final class PlaybackAnalyticsTests: XCTestCase {
    func testTracksStartupBufferingWatchDurationAndFinalEngagement() {
        let analyticsClient = RecordingAnalyticsClient()
        let metricsClient = RecordingMetricsClient()
        let analytics = PlaybackAnalytics(
            analyticsClient: analyticsClient,
            metricsClient: metricsClient
        )

        analytics.beginSession(mediaId: "media-123", startedAt: 100)
        analytics.observe(state: .loading, at: 100)
        analytics.observe(state: .playing, at: 102.5)
        analytics.observe(state: .buffering, at: 105)
        analytics.observe(state: .playing, at: 107)
        analytics.observe(state: .paused, at: 110)
        analytics.finishSession(at: 111)

        let startup = metricsClient.durations.first {
            $0.name == "player.startup.duration"
        }
        XCTAssertEqual(startup?.milliseconds, 2500)
        XCTAssertEqual(startup?.tags["media_id"], "media-123")

        let buffering = metricsClient.durations.first {
            $0.name == "player.buffering.duration"
        }
        XCTAssertEqual(buffering?.milliseconds, 2000)

        let watchDurations = metricsClient.durations
            .filter { $0.name == "player.watch.duration" }
            .map(\.milliseconds)
        XCTAssertEqual(watchDurations, [2500, 3000])

        let engagement = analyticsClient.events.first {
            $0.name == "Personalized content engagement"
        }
        XCTAssertEqual(engagement?.properties["media_id"], "media-123")
        XCTAssertEqual(engagement?.properties["watch_time_ms"], "5500")
        XCTAssertEqual(engagement?.properties["loop_count"], "0")
        XCTAssertEqual(engagement?.properties["signal_type"], "WATCH")
        XCTAssertNotNil(engagement?.properties["session_id"])
    }

    func testCountsOnlyACompletedPassThatActuallyStartsAgainAsALoop() {
        let analyticsClient = RecordingAnalyticsClient()
        let metricsClient = RecordingMetricsClient()
        let analytics = PlaybackAnalytics(
            analyticsClient: analyticsClient,
            metricsClient: metricsClient
        )

        analytics.beginSession(mediaId: "looping-media", startedAt: 10)
        analytics.observe(state: .playing, at: 11)
        analytics.observe(event: .playbackCompleted, at: 20)
        analytics.observe(event: .playbackStarted, at: 20.1)
        analytics.observe(state: .playing, at: 20.1)
        analytics.observe(event: .playbackCompleted, at: 30)
        analytics.finishSession(at: 31)

        let loopMetric = metricsClient.counters.first {
            $0.name == "player.loop.count"
        }
        XCTAssertEqual(loopMetric?.tags["loop_index"], "1")

        let engagement = analyticsClient.events.first {
            $0.name == "Personalized content engagement"
        }
        XCTAssertEqual(engagement?.properties["loop_count"], "1")
    }

    func testFinishingActivePlaybackClosesWatchSegmentAndIsIdempotent() {
        let analyticsClient = RecordingAnalyticsClient()
        let metricsClient = RecordingMetricsClient()
        let analytics = PlaybackAnalytics(
            analyticsClient: analyticsClient,
            metricsClient: metricsClient
        )

        analytics.beginSession(mediaId: "active-media", startedAt: 1)
        analytics.observe(state: .playing, at: 2)
        analytics.finishSession(at: 5)
        analytics.finishSession(at: 9)

        let reports = analyticsClient.events.filter {
            $0.name == "Personalized content engagement"
        }
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.properties["watch_time_ms"], "3000")
    }

    func testRecordsAnInitialPlaybackFailureWithoutAnActiveSession() {
        let analyticsClient = RecordingAnalyticsClient()
        let analytics = PlaybackAnalytics(
            analyticsClient: analyticsClient,
            metricsClient: NoopMetricsClient()
        )

        analytics.recordFailure(
            .playbackStalled,
            mediaId: "failed-media",
            at: 42
        )

        let error = analyticsClient.events.first {
            $0.name == "Media player error"
        }
        XCTAssertEqual(error?.properties["media_id"], "failed-media")
        XCTAssertEqual(error?.properties["error_type"], "playbackStalled")
    }

    func testDoesNotCreateNegativeOrNonFiniteDurations() {
        let analyticsClient = RecordingAnalyticsClient()
        let metricsClient = RecordingMetricsClient()
        let analytics = PlaybackAnalytics(
            analyticsClient: analyticsClient,
            metricsClient: metricsClient
        )

        analytics.beginSession(mediaId: "backwards-clock", startedAt: 10)
        analytics.observe(state: .playing, at: 9)
        analytics.observe(state: .paused, at: 8)
        analytics.finishSession(at: 8)

        analytics.beginSession(mediaId: "non-finite-clock", startedAt: 1)
        analytics.observe(state: .playing, at: .nan)
        analytics.observe(state: .paused, at: .infinity)

        XCTAssertTrue(metricsClient.durations.isEmpty)
    }
}
