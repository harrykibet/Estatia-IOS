//
//  PlayerActor.swift
//  CorePlayerEngine
//
//  Responsibility:
//  - Central state machine for playback
//  - Owns authoritative PlayerState
//  - Consumes PlayerEvent signals from AV layer
//  - Emits PlayerEvent + PlayerState externally
//
//  Design:
//  - Actor = single-threaded state authority
//  - Intent-driven API (PlayerIntent)
//  - Event-driven internal updates
//  - No direct AVFoundation coupling
//

import Foundation

actor PlayerActor {
    
    // MARK: - Dependencies
    
    private let config: PlayerConfiguration
    private let player: PlayerTransport
    
    private let stateEmitter: PlayerEventEmitter<PlayerState>
    private let eventEmitter: PlayerEventEmitter<PlayerEvent>
    
    private let watchdog: PlaybackWatchdog
    private let transportEventContinuation:
        AsyncStream<PlayerActorEvent>.Continuation
    private let transportEventStream: AsyncStream<PlayerActorEvent>
    private var transportEventTask: Task<Void, Never>?
    
    // MARK: - State
    
    private var reducer = PlaybackStateReducer()
    private var currentSource: MediaSource?
    private var currentMediaId: String?
    private var didAttemptBaselineCodecFallback = false
    
    private var currentTimeInternal: TimeInterval = 0
    private var durationInternal: TimeInterval?

    /// Desired playback intent is separate from observed transport state.
    /// A play/pause command changes this value; AVPlayer KVO changes reducer state.
    private var wantsPlayback = false

    /// An OS interruption temporarily pauses the transport while preserving
    /// wantsPlayback. A user pause during the interruption still clears intent.
    private var isAudioInterrupted = false

    /// Recovery loads defer resumption until the orchestrator validates ownership.
    private var isLoadingForNetworkRecovery = false
    private var isLoadingForCodecFallback = false
    private var recoveryResumeAuthorized = false
    
    // MARK: - Initialization
    
    init(
        config: PlayerConfiguration,
        player: PlayerTransport,
        watchdog: PlaybackWatchdog,
        stateEmitter: PlayerEventEmitter<PlayerState>,
        eventEmitter: PlayerEventEmitter<PlayerEvent>
    ) {
        self.config = config
        self.player = player
        self.watchdog = watchdog
        self.stateEmitter = stateEmitter
        self.eventEmitter = eventEmitter

        let eventStream = AsyncStream<PlayerActorEvent>.makeStream()
        self.transportEventContinuation = eventStream.continuation
        self.transportEventStream = eventStream.stream

        let continuation = eventStream.continuation

        player.onReady = {
            continuation.yield(.ready)
        }

        player.onTransportStatus = { status in
            continuation.yield(.transportStatus(status))
        }

        player.onError = { error in
            continuation.yield(
                .failed(
                    PlayerError.from(error)
                )
            )
        }

        player.onCompletion = {
            continuation.yield(.playbackCompleted)
        }

        player.onProgress = { progress in
            continuation.yield(.progress(progress))
        }

        // Start consuming after initialization has completed. Events emitted
        // before the consumer starts remain buffered by AsyncStream.
        Task { [weak self] in
            await self?.startEventConsumption()
        }
    }

    private func startEventConsumption() {
        guard transportEventTask == nil else {
            return
        }

        let stream = transportEventStream
        transportEventTask = Task { [weak self] in
            for await event in stream {
                guard let self else {
                    return
                }

                await self.consume(event)
            }
        }
    }
    
    deinit {
        transportEventContinuation.finish()
        transportEventTask?.cancel()
        player.release()
    }
    
    // MARK: - Snapshots
    
    var currentState: PlayerState {
        reducer.state
    }

    var shouldResumeAfterInterruption: Bool {
        wantsPlayback
    }
    
    var currentTime: TimeInterval {
        currentTimeInternal
    }
    
    var duration: TimeInterval? {
        durationInternal
    }
    
    // MARK: - Event Consumption
    
    private func consume(
        _ event: PlayerActorEvent
    ) async {
        switch event {
            
        case .ready:
            
            await watchdog.cancel()
            
            apply(.ready)
            emit(.ready)
            
            let wasManagedReload = isLoadingForNetworkRecovery || isLoadingForCodecFallback
            isLoadingForNetworkRecovery = false
            isLoadingForCodecFallback = false

            if wasManagedReload {
                let resumeWasAuthorized = recoveryResumeAuthorized
                recoveryResumeAuthorized = false
                if resumeWasAuthorized {
                    try? await handle(.play)
                }
            } else if wantsPlayback || config.autoPlay {
                // A play request may arrive before AVPlayer reports ready.
                try? await handle(.play)
            }
            
        case .transportStatus(let status):
            await consumeTransportStatus(status)

        case .playbackCompleted:
            wantsPlayback = false
            await watchdog.cancel()
            apply(.playbackCompleted)
            emit(.playbackCompleted)
            
            if config.looping {
                try? await replayFromBeginning()
            }
            
        case .failed(let error):
            isLoadingForNetworkRecovery = false
            isLoadingForCodecFallback = false
            recoveryResumeAuthorized = false
            await watchdog.cancel()

            if await attemptBaselineCodecFallback(for: error) {
                return
            }

            handlePlaybackFailure(error)
            
        case .progress(let progress):
            currentTimeInternal = progress.currentTime
            durationInternal = progress.duration
            emit(.progress(progress))
            
        case .watchdogExpired:
            wantsPlayback = false
            player.pause()
            apply(.watchdogExpired)
            emit(.failed(.playbackStalled))
        }
    }
    
    // MARK: - Observed Transport State

    private func consumeTransportStatus(
        _ status: PlayerTransportStatus
    ) async {
        switch status {
        case .waiting:
            // Waiting is meaningful only while playback is desired. A paused
            // player commonly has isPlaybackLikelyToKeepUp == false.
            guard wantsPlayback,
                  !isAudioInterrupted,
                  reducer.state != .reconnecting,
                  reducer.state != .buffering
            else {
                return
            }

            let previous = reducer.state
            apply(.bufferingStarted)

            guard previous != reducer.state,
                  reducer.state == .buffering
            else {
                return
            }

            let continuation = transportEventContinuation
            await watchdog.start {
                continuation.yield(.watchdogExpired)
            }

            emit(.bufferingStarted)

        case .playing:
            guard wantsPlayback, !isAudioInterrupted else {
                return
            }

            await watchdog.cancel()

            // The first observed playback after network recovery confirms
            // that transport has recovered; do not infer recovery from a
            // successful load or a play command.
            if reducer.state == .reconnecting {
                apply(.networkRestored)
            }

            let previous = reducer.state
            let wasBuffering = previous == .buffering
            apply(.transportPlaying)

            if previous != reducer.state,
               reducer.state == .playing {
                if wasBuffering {
                    emit(.bufferingEnded)
                }
                emit(.playbackStarted)
            }

        case .paused:
            guard !wantsPlayback || isAudioInterrupted else {
                return
            }

            await watchdog.cancel()

            let previous = reducer.state
            let wasBuffering = previous == .buffering
            apply(.transportPaused)

            if previous != reducer.state,
               reducer.state == .paused {
                if wasBuffering {
                    emit(.bufferingEnded)
                }
                emit(.playbackPaused)
            }
        }
    }

    // MARK: - Public Intent Handling

    /// Replaces the item after connectivity returns without applying the
    /// configured auto-play policy. The orchestrator authorizes any resumption.
    func loadForNetworkRecovery(
        mediaId: String,
        source: MediaSource
    ) async throws {
        await watchdog.cancel()
        isLoadingForNetworkRecovery = true
        isLoadingForCodecFallback = false
        recoveryResumeAuthorized = false
        apply(.loadStarted)

        // Once this engine has fallen back, connectivity recovery must keep
        // using the Baseline rendition rather than re-requesting the failed
        // AV1/HEVC variant from the orchestrator's original source snapshot.
        let recoverySource = didAttemptBaselineCodecFallback
            ? (CodecBaselineFallbackPolicy.fallbackSource(for: source) ?? source)
            : source
        currentMediaId = mediaId
        currentSource = recoverySource

        do {
            try await player.load(mediaId: mediaId, source: recoverySource)
        } catch {
            isLoadingForNetworkRecovery = false
            recoveryResumeAuthorized = false
            handlePlaybackFailure(error)
            throw error
        }
    }

    func handle(
        _ intent: PlayerIntent
    ) async throws {
        
        switch intent {
            
        case .load(let source):
            
            await watchdog.cancel()
            wantsPlayback = false
            isLoadingForNetworkRecovery = false
            isLoadingForCodecFallback = false
            recoveryResumeAuthorized = false
            apply(.loadStarted)

            let mediaId = source.url.absoluteString
            prepareForExplicitLoad(mediaId: mediaId, source: source)

            do {
                try await player.load(
                    mediaId:
                        mediaId,
                    source:
                        source
                )
            } catch {
                handlePlaybackFailure(error)
                throw error
            }

        case let .loadIdentified(
            mediaId: mediaId,
            source: source
        ):
            
            await watchdog.cancel()
            wantsPlayback = false
            isLoadingForNetworkRecovery = false
            isLoadingForCodecFallback = false
            recoveryResumeAuthorized = false
            apply(.loadStarted)

            prepareForExplicitLoad(mediaId: mediaId, source: source)

            do {
                try await player.load(
                    mediaId:
                        mediaId,
                    source:
                        source
                )
            } catch {
                handlePlaybackFailure(error)
                throw error
            }
            
        case .play:

            // A user/system play command during an interruption updates the
            // desired state but cannot restart transport until the interruption
            // has ended.
            if isAudioInterrupted {
                wantsPlayback = true
                if isLoadingForNetworkRecovery || isLoadingForCodecFallback {
                    recoveryResumeAuthorized = true
                }
                return
            }

            if reducer.state == .loading {
                wantsPlayback = true
                if isLoadingForNetworkRecovery || isLoadingForCodecFallback {
                    recoveryResumeAuthorized = true
                }
                return
            }

            guard reducer.state.isPlayable else {
                return
            }
            
            if reducer.state == .ended {
                try await player.seek(to: 0)
            }

            wantsPlayback = true
            player.play()
            
        case .pause:
            
            guard wantsPlayback ||
                  reducer.state == .playing ||
                  reducer.state == .buffering ||
                  reducer.state == .reconnecting
            else {
                return
            }

            wantsPlayback = false
            recoveryResumeAuthorized = false
            player.pause()

        case .audioInterruptionBegan:
            // Mark the engine interrupted even when it was already paused:
            // a play command received during the interruption must be held
            // until AVAudioSession reports that interruption has ended.
            isAudioInterrupted = true
            if wantsPlayback || reducer.state == .playing ||
                reducer.state == .buffering || reducer.state == .reconnecting {
                player.pause()
            }

        case .audioInterruptionEnded(let shouldResume):
            guard isAudioInterrupted else { return }
            isAudioInterrupted = false

            guard shouldResume, wantsPlayback else {
                wantsPlayback = false
                recoveryResumeAuthorized = false
                return
            }

            if reducer.state == .loading {
                if isLoadingForNetworkRecovery || isLoadingForCodecFallback {
                    recoveryResumeAuthorized = true
                }
                return
            }

            guard reducer.state.isPlayable else { return }

            if reducer.state == .ended {
                try await player.seek(to: 0)
            }
            player.play()

        case .seek(let seconds):
            
            guard reducer.state.isSeekable else {
                return
            }
            
            emit(
                .seekStarted(seconds)
            )
            
            do {
                try await player.seek(
                    to: max(0, seconds)
                )
                
                emit(
                    .seekCompleted(seconds)
                )
                
            } catch {
                emit(
                    .seekFailed(
                        PlayerError.from(error)
                    )
                )
                
                throw error
            }
            
        case .stop:
            
            await watchdog.cancel()
            wantsPlayback = false
            isAudioInterrupted = false
            isLoadingForNetworkRecovery = false
            isLoadingForCodecFallback = false
            recoveryResumeAuthorized = false
            didAttemptBaselineCodecFallback = false
            player.stop()
            
            apply(.reset)
            
            emit(.stopped)
            
        case .release:
            
            await watchdog.cancel()
            wantsPlayback = false
            isAudioInterrupted = false
            isLoadingForNetworkRecovery = false
            isLoadingForCodecFallback = false
            recoveryResumeAuthorized = false
            didAttemptBaselineCodecFallback = false
            player.release()
            
            apply(.released)
            
            emit(.released)
            
        default:
            break
        }
    }
    

    // MARK: - Codec Fallback

    private func prepareForExplicitLoad(
        mediaId: String,
        source: MediaSource
    ) {
        if currentMediaId != mediaId || currentSource != source {
            didAttemptBaselineCodecFallback = false
        }

        currentMediaId = mediaId
        currentSource = source
    }

    /// Retries a decoder-specific failure with the H.264 Baseline rendition.
    /// This remains inside the same PlayerActor/PlayerTransport ownership path.
    private func attemptBaselineCodecFallback(
        for error: PlayerError
    ) async -> Bool {
        guard error == .decoderUnavailable,
              wantsPlayback,
              !didAttemptBaselineCodecFallback,
              let mediaId = currentMediaId,
              let source = currentSource,
              let fallbackSource = CodecBaselineFallbackPolicy.fallbackSource(for: source)
        else {
            return false
        }

        didAttemptBaselineCodecFallback = true
        currentSource = fallbackSource
        isLoadingForCodecFallback = true
        recoveryResumeAuthorized = wantsPlayback
        apply(.loadStarted)

        do {
            try await player.load(
                mediaId: mediaId,
                source: fallbackSource
            )
        } catch {
            isLoadingForCodecFallback = false
            recoveryResumeAuthorized = false
            handlePlaybackFailure(error)
        }

        return true
    }

    // MARK: - State Helpers
    
    private func apply(
        _ event: PlaybackStateReducer.Event
    ) {
        let previous = reducer.state
        
        let newState = reducer.reduce(event)
        
        guard newState != previous else {
            return
        }
        
        stateEmitter.emit(newState)
    }
    
    private func handlePlaybackFailure(
        _ error: Error
    ) {
        
        handlePlaybackFailure(
            PlayerError.from(error)
        )
    }
    
    private func handlePlaybackFailure(
        _ error: PlayerError
    ) {
        switch error {
            
        case .network:
            
            apply(.networkLost(resumePlayback: wantsPlayback))
            
            emit(.failed(error))
            
        default:

            wantsPlayback = false
            apply(
                .failed(error)
            )
            
            emit(
                .failed(error)
            )
        }
    }
    
    private func replayFromBeginning() async throws {
        
        try await player.seek(
            to: 0
        )

        wantsPlayback = true
        player.play()
    }
    
    private func emit(
        _ event: PlayerEvent
    ) {
        eventEmitter.emit(event)
    }
    
    func notifyNetworkLost() async {
        await watchdog.cancel()
        apply(.networkLost(resumePlayback: wantsPlayback))
    }
    
    func notifyRecoveryExhausted() async {
        await watchdog.cancel()
        wantsPlayback = false
        isLoadingForNetworkRecovery = false
        recoveryResumeAuthorized = false
        player.pause()
        
        let error = PlayerError.network(
            .retryExhausted
        )
        
        apply(
            .failed(error)
        )
        
        emit(
            .failed(error)
        )
    }
}

// MARK: - Internal Actor Events

private enum PlayerActorEvent: Sendable {

    case ready

    case transportStatus(PlayerTransportStatus)

    case playbackCompleted
    
    case watchdogExpired

    case failed(PlayerError)

    case progress(PlaybackProgress)
}
