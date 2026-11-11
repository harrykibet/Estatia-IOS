//
//  AVPlayerProviding.swift
//  CorePlayerEngine
//
//  Presentation and playback-tuning bridge for AVFoundation.
//

import AVFoundation

/// Exposes the AVPlayer owned by an AVFoundation-backed engine for native
/// video rendering and controlled playback tuning. Playback commands and
/// authoritative state remain owned by PlayerEngine.
@MainActor
public protocol AVPlayerProviding: AnyObject {
    var presentationPlayer: AVPlayer? { get }

    /// Latest positive throughput estimate reported by the current item's
    /// AVPlayer access log, when available.
    var observedBitrateBps: Double? { get }

    /// Sets AVPlayerItem.preferredPeakBitRate. Pass zero to remove the cap.
    func setPreferredPeakBitRate(_ bitrateBps: Double)

    /// Applies match-score and environment-derived limits to the current item.
    func setPlaybackQuality(_ preferences: PlaybackQualityPreferences)
}
