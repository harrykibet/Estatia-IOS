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

@MainActor
final class PlaybackAnalyticsTests: XCTestCase {
    func testTracksStartupBufferingWatchDurationAndFinalEngagement() {
        let client = RecordingAnalyticsClient()
        let analytics = PlaybackAnalytics(analyticsClient: client)

        analytics.beginSession(mediaId: "media-123", startedAt: 100)
        analytics.observe(state: .loading, at: 100)
        analytics.observe(state: .playing, at: 102.5)
        analytics.observe(state: .buffering, at: 105)
        analytics.observe(state: .playing, at: 107)
        analytics.observe(state: .paused, at: 110)
        analytics.finishSession(at: 111)

        let startup = client.events.first { $0.name == "player.startup.duration" }
        XCTAssertEqual(startup?.properties["duration_ms"], "2500")
        XCTAssertEqual(startup?.properties["media_id"], "media-123")

        let buffering = client.events.first { $0.name == "player.buffering.duration" }
        XCTAssertEqual(buffering?.properties["duration_ms"], "2000")

        let watchDurations = client.events
            .filter { $0.name == "player.watch.duration" }
            .compactMap { $0.properties["duration_ms"] }
        XCTAssertEqual(watchDurations, ["2500", "3000"])

        let engagement = client.events.first {
            $0.name == "Personalized content engagement"
        }
        XCTAssertEqual(engagement?.properties["media_id"], "media-123")
        XCTAssertEqual(engagement?.properties["watch_time_ms"], "5500")
        XCTAssertEqual(engagement?.properties["loop_count"], "0")
        XCTAssertEqual(engagement?.properties["signal_type"], "WATCH")
        XCTAssertNotNil(engagement?.properties["session_id"])
    }

    func testCountsOnlyACompletedPassThatActuallyStartsAgainAsALoop() {
        let client = RecordingAnalyticsClient()
        let analytics = PlaybackAnalytics(analyticsClient: client)

        analytics.beginSession(mediaId: "looping-media", startedAt: 10)
        analytics.observe(state: .playing, at: 11)
        analytics.observe(event: .playbackCompleted, at: 20)
        analytics.observe(event: .playbackStarted, at: 20.1)
        analytics.observe(state: .playing, at: 20.1)
        analytics.observe(event: .playbackCompleted, at: 30)
        analytics.finishSession(at: 31)

        let loopMetric = client.events.first { $0.name == "player.loop.count" }
        XCTAssertEqual(loopMetric?.properties["loop_index"], "1")

        let engagement = client.events.first {
            $0.name == "Personalized content engagement"
        }
        XCTAssertEqual(engagement?.properties["loop_count"], "1")
    }

    func testFinishingActivePlaybackClosesWatchSegmentAndIsIdempotent() {
        let client = RecordingAnalyticsClient()
        let analytics = PlaybackAnalytics(analyticsClient: client)

        analytics.beginSession(mediaId: "active-media", startedAt: 1)
        analytics.observe(state: .playing, at: 2)
        analytics.finishSession(at: 5)
        analytics.finishSession(at: 9)

        let reports = client.events.filter {
            $0.name == "Personalized content engagement"
        }
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.properties["watch_time_ms"], "3000")
    }

    func testRecordsAnInitialPlaybackFailureWithoutAnActiveSession() {
        let client = RecordingAnalyticsClient()
        let analytics = PlaybackAnalytics(analyticsClient: client)

        analytics.recordFailure(
            .playbackStalled,
            mediaId: "failed-media",
            at: 42
        )

        let error = client.events.first { $0.name == "Media player error" }
        XCTAssertEqual(error?.properties["media_id"], "failed-media")
        XCTAssertEqual(error?.properties["error_type"], "playbackStalled")
    }
}
