//
//  PlaybackAnalytics.swift
//  CorePlayerEngine
//
//  Session-scoped playback QoS and engagement reporting.
//

import CoreAnalytics
import Foundation

/// Converts authoritative player state and events into playback QoS metrics
/// and the personalized-watch signals emitted by the Android player engine.
@MainActor
public final class PlaybackAnalytics {

    private let analyticsClient: any AnalyticsClient
    private let metricsClient: any MetricsClient

    private var mediaId: String?
    private var sessionId: String?
    private var sessionStartedAt: TimeInterval?
    private var firstPlaybackReported = false
    private var playbackStartedAt: TimeInterval?
    private var bufferingStartedAt: TimeInterval?
    private var totalWatchTimeMs: Int64 = 0
    private var loopCount = 0
    private var completedPassAwaitingReplay = false
    private var lastState: PlayerState?

    public init(
        analyticsClient: any AnalyticsClient,
        metricsClient: any MetricsClient = NoopMetricsClient()
    ) {
        self.analyticsClient = analyticsClient
        self.metricsClient = metricsClient
    }

    /// Starts a new logical watch session. The supplied uptime is captured by
    /// PlayerManager when the play request begins, so startup latency includes
    /// player acquisition and media preparation.
    public func beginSession(
        mediaId: String,
        startedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        finishSession(at: startedAt)

        self.mediaId = mediaId
        sessionId = UUID().uuidString
        sessionStartedAt = startedAt
        firstPlaybackReported = false
        playbackStartedAt = nil
        bufferingStartedAt = nil
        totalWatchTimeMs = 0
        loopCount = 0
        completedPassAwaitingReplay = false
        lastState = nil
    }

    /// Consumes the engine's reduced state rather than sampling AVPlayer
    /// directly. Pauses, interruptions, buffering and recovery therefore use
    /// the same authoritative lifecycle as the UI.
    public func observe(
        state: PlayerState,
        at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard mediaId != nil, lastState != state else { return }

        if state == .playing {
            if !firstPlaybackReported, let sessionStartedAt {
                let startupMs = elapsedMilliseconds(from: sessionStartedAt, to: uptime)
                if startupMs > 0 {
                    metricsClient.trackDuration(
                        name: "player.startup.duration",
                        durationMilliseconds: startupMs,
                        tags: currentTags()
                    )
                }
                firstPlaybackReported = true
            }

            closeBufferingSegment(at: uptime)
            if playbackStartedAt == nil {
                playbackStartedAt = uptime
            }
        } else {
            closePlaybackSegment(at: uptime)
        }

        if state == .buffering || state == .reconnecting {
            if bufferingStartedAt == nil {
                bufferingStartedAt = uptime
            }
        } else {
            closeBufferingSegment(at: uptime)
        }

        lastState = state
    }

    /// A loop is counted only when playback starts again after a completed
    /// pass. Reaching the end without a subsequent replay is not a loop.
    public func observe(
        event: PlayerEvent,
        at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard mediaId != nil else { return }

        switch event {
        case .playbackStarted:
            if completedPassAwaitingReplay {
                loopCount += 1
                metricsClient.incrementCounter(
                    name: "player.loop.count",
                    tags: currentTags(extra: ["loop_index": String(loopCount)])
                )
            }
            completedPassAwaitingReplay = false
            trackEvent("Media player playback started")

        case .playbackPaused:
            trackEvent("Media player paused")

        case .playbackCompleted:
            completedPassAwaitingReplay = true
            trackEvent("Media player playback ended")

        case .bufferingStarted:
            trackEvent("Media player buffering started")

        case .bufferingEnded:
            trackEvent("Media player buffering ended")

        case .failed(let error):
            recordFailure(error, mediaId: mediaId, at: uptime)

        case .stopped, .released:
            finishSession(at: uptime)

        default:
            break
        }
    }

    /// Records a playback failure, including failures that occur before
    /// PlayerManager has attached to the new engine's event stream.
    public func recordFailure(
        _ error: PlayerError,
        mediaId: String,
        at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        var properties = ["media_id": mediaId, "error_type": String(describing: error)]
        if let sessionId {
            properties["session_id"] = sessionId
        }
        analyticsClient.track(name: "Media player error", properties: properties)
    }

    /// Ends the active session once and emits the final personalized watch
    /// signal with the Android-compatible metadata contract.
    public func finishSession(
        at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard let mediaId else { return }

        closePlaybackSegment(at: uptime)
        closeBufferingSegment(at: uptime)

        var properties = [
            "media_id": mediaId,
            "watch_time_ms": String(totalWatchTimeMs),
            "loop_count": String(loopCount),
            "signal_type": "WATCH"
        ]
        if let sessionId {
            properties["session_id"] = sessionId
        }

        analyticsClient.track(
            name: "Personalized content engagement",
            properties: properties
        )

        self.mediaId = nil
        sessionId = nil
        sessionStartedAt = nil
        firstPlaybackReported = false
        playbackStartedAt = nil
        bufferingStartedAt = nil
        totalWatchTimeMs = 0
        loopCount = 0
        completedPassAwaitingReplay = false
        lastState = nil
    }

    private func closePlaybackSegment(at uptime: TimeInterval) {
        guard let startedAt = playbackStartedAt else { return }
        let durationMs = elapsedMilliseconds(from: startedAt, to: uptime)
        playbackStartedAt = nil
        guard durationMs > 0 else { return }

        totalWatchTimeMs += durationMs
        metricsClient.trackDuration(
            name: "player.watch.duration",
            durationMilliseconds: durationMs,
            tags: currentTags()
        )
    }

    private func closeBufferingSegment(at uptime: TimeInterval) {
        guard let startedAt = bufferingStartedAt else { return }
        let durationMs = elapsedMilliseconds(from: startedAt, to: uptime)
        bufferingStartedAt = nil
        guard durationMs > 0 else { return }

        metricsClient.trackDuration(
            name: "player.buffering.duration",
            durationMilliseconds: durationMs,
            tags: currentTags()
        )
    }

    private func trackEvent(_ name: String) {
        analyticsClient.track(name: name, properties: currentTags())
    }

    private func currentTags(
        extra: [String: String] = [:]
    ) -> [String: String] {
        var tags = extra
        if let mediaId {
            tags["media_id"] = mediaId
        }
        if let sessionId {
            tags["session_id"] = sessionId
        }
        return tags
    }

    private func elapsedMilliseconds(
        from start: TimeInterval,
        to end: TimeInterval
    ) -> Int64 {
        guard start.isFinite, end.isFinite, end > start else { return 0 }
        let milliseconds = (end - start) * 1_000
        guard milliseconds.isFinite else { return 0 }
        return Int64(min(milliseconds.rounded(), Double(Int64.max) / 2))
    }
}
