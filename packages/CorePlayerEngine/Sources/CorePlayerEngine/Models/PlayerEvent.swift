//
//  PlayerEvent.swift
//  CorePlayerEngine
//
//  Created by builder on 3/26/26.
//

import Foundation

// MARK: - PlayerEvent

public enum PlayerEvent: Sendable {
    
    // MARK: Lifecycle
    
    case ready
    case released
    case stopped
    
    
    // MARK: Playback
    
    case playbackStarted
    case playbackPaused
    case playbackCompleted
    
    
    // MARK: Buffering
    
    case bufferingStarted
    case bufferingEnded
    
    // MARK: Watchdog
    
    case watchdogExpired
    
    
    // MARK: Seeking
    
    case seekStarted(TimeInterval)
    case seekCompleted(TimeInterval)
    case seekFailed(PlayerError)
    
    
    // MARK: Progress
    
    case progress(PlaybackProgress)

    /// Changes when sustained low throughput crosses the warning/recovery thresholds.
    case lowBandwidthChanged(isSustained: Bool)
    
    
    // MARK: Errors
    
    case failed(PlayerError)
}
