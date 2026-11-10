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

    /// Starts visible playback and reports the managed engine as soon as
    /// ownership is committed, without waiting for speculative cache warming.
    func play(
        mediaId: String,
        source: MediaSource,
        onEngineReady: @escaping @MainActor @Sendable ((any PlayerEngine)?) async -> Void
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

    /// Returns the engine currently owned by the requested media identity.
    /// Targets that cannot expose an engine may keep the default nil behavior.
    func playerEngine(for mediaId: String) async -> (any PlayerEngine)?

    func isMediaActive(
        _ mediaId: String
    ) -> Bool

    func pauseCurrent() async
}

public extension VideoPlaybackTarget {
    /// Custom playback targets may opt into invalidation; the orchestrator
    /// provides the concrete cancellation and transport-cleanup behavior.
    func invalidatePendingPlaybackRequest() {}

    func playerEngine(for mediaId: String) async -> (any PlayerEngine)? {
        nil
    }

    func play(
        mediaId: String,
        source: MediaSource,
        onEngineReady: @escaping @MainActor @Sendable ((any PlayerEngine)?) async -> Void
    ) async throws {
        try await play(mediaId: mediaId, source: source)
        await onEngineReady(await playerEngine(for: mediaId))
    }
}

extension PlaybackOrchestrator:
    VideoPlaybackTarget {}