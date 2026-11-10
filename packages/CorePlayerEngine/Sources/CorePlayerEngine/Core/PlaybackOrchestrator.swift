//
//  PlaybackOrchestrator.swift
//  CorePlayerEngine
//
//  Created by builder on 9/18/26.
//

import Foundation

/// Coordinates playback across multiple pooled PlayerEngine instances.
///
/// Responsibilities:
/// - determines which media is currently active
/// - pauses the previous active player
/// - prevents stale play requests from taking ownership
/// - delegates player acquisition/reuse to PlayerPool
/// - delegates streaming warm-up to StreamingPipeline
/// - provides playback state observation
///
/// Non-responsibilities:
/// - player state reduction
/// - AVFoundation operations
/// - audio-session management
/// - CDN selection
/// - bitrate policy
/// - network recovery
///
/// Those belong to specialized components.
@MainActor
public final class PlaybackOrchestrator {

    // MARK: - Dependencies

    private let pool: PlayerPool
    private let streamingPipeline: StreamingPipeline

    // MARK: - State

    public private(set) var activeMediaId: String?

    /// Identifies the most recently requested media while acquisition or
    /// transport commands are still in flight. This lets a later request
    /// supersede an earlier request before it becomes the committed owner.
    private var pendingMediaId: String?

    /// Monotonically increasing request generation. Every user playback
    /// command that changes ownership invalidates older suspended work.
    private var playGeneration: UInt64 = 0

    private struct ActivePlayback: Sendable {
        let mediaId: String
        let source: MediaSource
    }

    private var activePlayback: ActivePlayback?

    // MARK: - Init

    public init(
        pool: PlayerPool,
        streamingPipeline: StreamingPipeline
    ) {
        self.pool = pool
        self.streamingPipeline = streamingPipeline
    }

    // MARK: - Play

    public func play(
        mediaId: String,
        source: MediaSource
    ) async throws {
        try await playInternal(
            mediaId: mediaId,
            source: source,
            onEngineReady: nil
        )
    }

    public func playWithEngineReady(
        mediaId: String,
        source: MediaSource,
        onEngineReady: @escaping @MainActor @Sendable ((any PlayerEngine)?) async -> Void
    ) async throws {
        try await playInternal(
            mediaId: mediaId,
            source: source,
            onEngineReady: { engine in
                await onEngineReady(engine)
            }
        )
    }

    private func playInternal(
        mediaId: String,
        source: MediaSource,
        onEngineReady: (@MainActor @Sendable (any PlayerEngine) async -> Void)?
    ) async throws {

        playGeneration &+= 1

        let generation = playGeneration
        let previousMediaId = pendingMediaId ?? activeMediaId
        pendingMediaId = mediaId

        do {
            // Stop the previous logical owner first. A per-player operation
            // queue ensures this pause cannot overtake an earlier play/stop.
            if let previousMediaId,
               previousMediaId != mediaId,
               let previous = await pool.get(mediaId: previousMediaId) {

                try requireCurrentGeneration(generation)

                try? await previous.perform {
                    try await previous.engine.pause()
                }

                try requireCurrentGeneration(generation)
            }

            let managed = try await pool.getOrCreate(
                mediaId: mediaId,
                source: source
            )

            // Do not issue commands through a stale ManagedPlayer reference:
            // the pool may have recycled that same object for another media ID.
            try requireCurrentGeneration(generation)

            guard managed.mediaId == mediaId else {
                throw CancellationError()
            }

            try await managed.perform {
                try await managed.engine.play()
            }

            // If a newer request arrived while play() was suspended, leave
            // correction to the newer request's serialized command sequence.
            // Issuing a stale pause here could pause a newly reused engine.
            try requireCurrentGeneration(generation)

            guard managed.mediaId == mediaId else {
                throw CancellationError()
            }

            activePlayback = ActivePlayback(
                mediaId: mediaId,
                source: source
            )

            activeMediaId = mediaId
            pendingMediaId = nil

            // Publish the exact engine now owned by this media identity before
            // the best-effort cache warm can delay mounting the feed surface.
            if let onEngineReady {
                await onEngineReady(managed.engine)
            }

            await streamingPipeline.warm(
                mediaId: mediaId,
                source: source,
                priority: .visible
            )
        } catch {
            if generation == playGeneration,
               pendingMediaId == mediaId {
                pendingMediaId = nil
            }

            throw error
        }
    }

    // MARK: - Pending Request Invalidation

    /// Supersedes a play request that has not committed ownership yet.
    ///
    /// If the request has already entered the transport, enqueue a compensating
    /// pause behind it. The media identity checks prevent that cleanup from
    /// pausing a player that has since been reused or reclaimed by a newer play.
    public func invalidatePendingPlaybackRequest() {
        guard let mediaId = pendingMediaId else {
            return
        }

        playGeneration &+= 1
        pendingMediaId = nil

        Task { @MainActor [weak self] in
            guard let self,
                  let managed = await self.pool.get(mediaId: mediaId),
                  managed.mediaId == mediaId,
                  self.pendingMediaId != mediaId,
                  self.activeMediaId != mediaId
            else {
                return
            }

            try? await managed.perform {
                guard managed.mediaId == mediaId,
                      self.pendingMediaId != mediaId,
                      self.activeMediaId != mediaId
                else {
                    return
                }

                try await managed.engine.pause()
            }
        }
    }

    // MARK: - Preload

    public func preload(
        mediaId: String,
        source: MediaSource
    ) async {
        _ = await pool.prewarm(
            mediaId: mediaId,
            source: source
        )
    }

    // MARK: - Pause

    public func pauseCurrent() async {

        // Invalidate pending play/recovery work before looking up the target.
        playGeneration &+= 1
        let generation = playGeneration

        let mediaId = pendingMediaId ?? activeMediaId
        pendingMediaId = nil

        guard let mediaId else {
            return
        }

        guard let managed = await pool.get(mediaId: mediaId),
              generation == playGeneration,
              managed.mediaId == mediaId
        else {
            return
        }

        try? await managed.perform {
            try await managed.engine.pause()
        }
    }

    // MARK: - Resume

    public func resumeCurrent() async throws {

        let generation = playGeneration

        guard pendingMediaId == nil,
              let mediaId = activeMediaId
        else {
            return
        }

        guard let managed = await pool.get(mediaId: mediaId) else {
            return
        }

        try requireCurrentGeneration(generation)

        guard activeMediaId == mediaId,
              managed.mediaId == mediaId
        else {
            throw CancellationError()
        }

        try await managed.perform {
            try await managed.engine.play()
        }

        try requireCurrentGeneration(generation)

        guard activeMediaId == mediaId,
              managed.mediaId == mediaId
        else {
            throw CancellationError()
        }
    }

    // MARK: - Stop

    public func stopCurrent() async {

        playGeneration &+= 1
        let generation = playGeneration

        let mediaId = pendingMediaId ?? activeMediaId
        pendingMediaId = nil

        guard let mediaId else {
            activeMediaId = nil
            activePlayback = nil
            return
        }

        guard let managed = await pool.get(mediaId: mediaId) else {
            guard generation == playGeneration else {
                return
            }

            activeMediaId = nil
            activePlayback = nil
            return
        }

        guard generation == playGeneration,
              managed.mediaId == mediaId
        else {
            return
        }

        try? await managed.perform {
            try await managed.engine.stop()
        }

        // stop() can suspend. A newer play request may have taken ownership
        // during that suspension, so the old completion must not clear it.
        guard generation == playGeneration else {
            return
        }

        activeMediaId = nil
        activePlayback = nil
        pendingMediaId = nil
    }

    // MARK: - Release

    public func release(
        mediaId: String
    ) async {

        if activeMediaId == mediaId ||
           pendingMediaId == mediaId {
            playGeneration &+= 1
            pendingMediaId = nil

            if activeMediaId == mediaId {
                activeMediaId = nil
                activePlayback = nil
            }
        }

        await pool.release(mediaId: mediaId)
    }

    // MARK: - State

    public func observeState(
        mediaId: String
    ) async -> AsyncStream<PlayerState>? {

        guard let managed = await pool.get(mediaId: mediaId),
              managed.mediaId == mediaId
        else {
            return nil
        }

        return managed.engine.state
    }

    /// Returns the player engine only while the pool still assigns it to this
    /// media identity. Feed UIs use this to render the already-managed engine
    /// rather than constructing a second AVPlayer.
    public func playerEngine(for mediaId: String) async -> (any PlayerEngine)? {
        guard let managed = await pool.get(mediaId: mediaId),
              managed.mediaId == mediaId
        else {
            return nil
        }
        return managed.engine
    }

    /// Observes engine events for an active or preloaded media identity.
    public func observeEvents(
        mediaId: String
    ) async -> AsyncStream<PlayerEvent>? {
        guard let managed = await pool.get(mediaId: mediaId),
              managed.mediaId == mediaId
        else {
            return nil
        }
        return managed.engine.events
    }

    /// Returns the AVFoundation tuning bridge for a currently managed player.
    public func avPlayerProvider(
        mediaId: String
    ) async -> (any AVPlayerProviding)? {
        guard let managed = await pool.get(mediaId: mediaId),
              managed.mediaId == mediaId
        else {
            return nil
        }
        return managed.engine as? any AVPlayerProviding
    }

    /// Delivers bandwidth quality changes to the engine without modifying
    /// its authoritative transport state (playing, buffering, paused, etc.).
    public func notifySustainedLowBandwidth(
        mediaId: String,
        isSustained: Bool
    ) async {
        guard pendingMediaId == nil,
              activeMediaId == mediaId,
              let managed = await pool.get(mediaId: mediaId)
        else {
            return
        }

        // Pool lookup is asynchronous; revalidate ownership before publishing
        // so an old media sample cannot affect a newly selected player.
        guard pendingMediaId == nil,
              activeMediaId == mediaId,
              managed.mediaId == mediaId
        else {
            return
        }

        await managed.engine.notifySustainedLowBandwidth(isSustained)
    }

    public func currentState(
        mediaId: String
    ) async -> PlayerState? {

        guard let managed = await pool.get(mediaId: mediaId),
              managed.mediaId == mediaId
        else {
            return nil
        }

        let state = await managed.engine.currentState

        guard managed.mediaId == mediaId else {
            return nil
        }

        return state
    }

    public func isCurrentlyPlaying() async -> Bool {

        guard let activeMediaId else {
            return false
        }

        return await currentState(
            mediaId: activeMediaId
        ) == .playing
    }

    public func isMediaActive(
        _ mediaId: String
    ) -> Bool {
        activeMediaId == mediaId
    }

    public func updateComposedMedia(
        _ mediaIds: Set<String>
    ) async {
        await pool.updatePinnedIds(mediaIds)
    }

    // MARK: - Shutdown

    public func shutdown() async {

        playGeneration &+= 1
        pendingMediaId = nil
        activeMediaId = nil
        activePlayback = nil

        await pool.releaseAll()
    }

    // MARK: - Request Validation

    private func requireCurrentGeneration(
        _ generation: UInt64
    ) throws {
        guard generation == playGeneration else {
            throw CancellationError()
        }
    }
}

@MainActor
extension PlaybackOrchestrator: PlaybackRecoveryTarget {

    public func markNetworkUnavailable() async {

        let generation = playGeneration

        guard pendingMediaId == nil,
              let mediaId = activeMediaId,
              let managed = await pool.get(mediaId: mediaId)
        else {
            return
        }

        guard generation == playGeneration,
              activeMediaId == mediaId,
              managed.mediaId == mediaId
        else {
            return
        }

        let state = await managed.engine.currentState

        guard generation == playGeneration,
              activeMediaId == mediaId,
              managed.mediaId == mediaId
        else {
            return
        }

        switch state {
        case .playing, .buffering, .ready:
            try? await managed.perform {
                await managed.engine.notifyNetworkLost()
            }

        default:
            break
        }
    }

    public func isActiveMediaReconnecting() async -> Bool {

        let generation = playGeneration

        guard pendingMediaId == nil,
              let mediaId = activeMediaId,
              let managed = await pool.get(mediaId: mediaId)
        else {
            return false
        }

        guard generation == playGeneration,
              activeMediaId == mediaId,
              managed.mediaId == mediaId
        else {
            return false
        }

        let state = await managed.engine.currentState

        guard generation == playGeneration,
              activeMediaId == mediaId,
              managed.mediaId == mediaId
        else {
            return false
        }

        return state == .reconnecting
    }

    public func recoverActivePlayback() async throws {

        let generation = playGeneration

        guard pendingMediaId == nil,
              let playback = activePlayback,
              activeMediaId == playback.mediaId
        else {
            return
        }

        guard let managed = await pool.get(mediaId: playback.mediaId) else {
            return
        }

        try requireCurrentGeneration(generation)

        guard activePlayback?.mediaId == playback.mediaId,
              managed.mediaId == playback.mediaId
        else {
            throw CancellationError()
        }

        // Recovery load and any resumed play are one serialized operation.
        // Capture intent before replacing the item, then revalidate ownership
        // before issuing play so stale recovery cannot restart old media.
        try await managed.perform {
            let shouldResume = await managed.engine.shouldResumeAfterInterruption

            try await managed.engine.loadForNetworkRecovery(
                mediaId: playback.mediaId,
                source: playback.source
            )

            try self.requireCurrentGeneration(generation)

            if shouldResume {
                try await managed.engine.play()
            }
        }

        try requireCurrentGeneration(generation)

        guard activePlayback?.mediaId == playback.mediaId,
              activeMediaId == playback.mediaId,
              managed.mediaId == playback.mediaId
        else {
            throw CancellationError()
        }
    }

    public func failActiveRecovery() async {

        let generation = playGeneration

        guard pendingMediaId == nil,
              let mediaId = activeMediaId,
              let managed = await pool.get(mediaId: mediaId)
        else {
            return
        }

        guard generation == playGeneration,
              activeMediaId == mediaId,
              managed.mediaId == mediaId
        else {
            return
        }

        try? await managed.perform {
            await managed.engine.notifyRecoveryExhausted()
        }
    }
}
