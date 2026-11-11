//
//  AVPlayerProviding.swift
//  CorePlayerEngine
//
//  Presentation and playback-tuning bridge for AVFoundation.
//

import AVFoundation

/// Snapshot of the current live offset and AVFoundation's recommended target.
/// Both values are measured in seconds relative to the end of the seekable range.
public struct LivePlaybackTiming: Equatable, Sendable {
    public let currentOffsetSeconds: TimeInterval
    public let recommendedOffsetSeconds: TimeInterval

    public init(
        currentOffsetSeconds: TimeInterval,
        recommendedOffsetSeconds: TimeInterval
    ) {
        self.currentOffsetSeconds = currentOffsetSeconds
        self.recommendedOffsetSeconds = recommendedOffsetSeconds
    }
}

/// Exposes the AVPlayer owned by an AVFoundation-backed engine for native
/// video rendering and controlled playback tuning. Playback commands and
/// authoritative state remain owned by PlayerEngine.
@MainActor
public protocol AVPlayerProviding: AnyObject {
    var presentationPlayer: AVPlayer? { get }

    /// Latest positive throughput estimate reported by the current item's
    /// AVPlayer access log, when available.
    var observedBitrateBps: Double? { get }

    /// Current and recommended live offsets, when the item is a live stream
    /// and AVFoundation has enough seekable-window information to calculate them.
    var livePlaybackTiming: LivePlaybackTiming? { get }

    /// Sets AVPlayerItem.preferredPeakBitRate. Pass zero to remove the cap.
    func setPreferredPeakBitRate(_ bitrateBps: Double)

    /// Applies match-score and environment-derived limits to the current item.
    func setPlaybackQuality(_ preferences: PlaybackQualityPreferences)

    /// Enables native preservation of the live offset after a buffering operation.
    func setLivePlaybackEnabled(_ enabled: Bool)

    /// Applies a temporary live-edge correction. Normal playback resumes at 1.0x.
    func setLivePlaybackSpeed(_ speed: Float)
}

public extension AVPlayerProviding {
    /// Compatibility defaults for custom presentation adapters that do not
    /// expose live timing or tune HLS.
    var livePlaybackTiming: LivePlaybackTiming? { nil }
    func setPlaybackQuality(_ preferences: PlaybackQualityPreferences) {}
    func setLivePlaybackEnabled(_ enabled: Bool) {}
    func setLivePlaybackSpeed(_ speed: Float) {}
}
