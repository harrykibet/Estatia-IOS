//
//  VideoPlaybackTarget.swift
//  CorePlayerEngine
//
//  Created by builder on 9/22/26.
//


import Foundation

@MainActor
public protocol VideoPlaybackTarget: AnyObject {

    var activeMediaId: String? { get }

    /// Invalidates a suspended play request that no longer owns feed visibility.
    func invalidatePendingPlaybackRequest()

    func play(
        mediaId: String,
        source: MediaSource
    ) async throws

    func preload(
        mediaId: String,
        source: MediaSource
    ) async

    func updateComposedMedia(
        _ mediaIds: Set<String>
    ) async

    func observeState(
        mediaId: String
    ) async -> AsyncStream<PlayerState>?

    func isMediaActive(
        _ mediaId: String
    ) -> Bool

    func pauseCurrent() async
}

public extension VideoPlaybackTarget {
    /// Custom playback targets may opt into invalidation; the orchestrator
    /// provides the concrete cancellation and transport-cleanup behavior.
    func invalidatePendingPlaybackRequest() {}
}

extension PlaybackOrchestrator:
    VideoPlaybackTarget {}