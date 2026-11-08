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
    
    // MARK: - State
    
    private var reducer = PlaybackStateReducer()
    private var currentSource: MediaSource?
    
    private var currentTimeInternal: TimeInterval = 0
    private var durationInternal: TimeInterval?

    /// Desired playback intent is separate from observed transport state.
    /// A play/pause command changes this value; AVPlayer KVO changes reducer state.
    private var wantsPlayback = false
    
    // MARK: - Initialization
    
    init(
        config: PlayerConfiguration,
        player: AVPlayerWrapper,
        watchdog: PlaybackWatchdog,
        stateEmitter: PlayerEventEmitter<PlayerState>,
        eventEmitter: PlayerEventEmitter<PlayerEvent>
    ) {
        self.config = config
        self.player = player
        self.watchdog = watchdog
        self.stateEmitter = stateEmitter
        self.eventEmitter = eventEmitter
        
        player.onReady = { [weak self] in
            guard let self else { return }
            
            Task {
                await self.consume(.ready)
            }
        }
        
        player.onTransportStatus = { [weak self] status in
            guard let self else { return }

            Task {
                await self.consume(
                    .transportStatus(status)
                )
            }
        }

        player.onError = { [weak self] error in
            guard let self else { return }
            
            Task {
                await self.consume(
                    .failed(
                        PlayerError.from(error)
                    )
                )
            }
        }
        
        player.onCompletion = { [weak self] in
            guard let self else {
                return
            }

            Task {
                await self.consume(
                    .playbackCompleted
                )
            }
        }
        
        player.onProgress = { [weak self] progress in
            guard let self else { return }
            
            Task {
                await self.consume(
                    .progress(progress)
                )
            }
        }
    }
    
    deinit {
        player.release()
    }
    
    // MARK: - Snapshots
    
    var currentState: PlayerState {
        reducer.state
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
            
            if config.autoPlay {
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
            wantsPlayback = false
            await watchdog.cancel()
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

            await watchdog.start { [weak self] in
                guard let self else { return }

                Task {
                    await self.consume(.watchdogExpired)
                }
            }

            emit(.bufferingStarted)

        case .playing:
            guard wantsPlayback else {
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
            apply(.transportPlaying)

            if previous != reducer.state,
               reducer.state == .playing {
                emit(.playbackStarted)
            }

        case .paused:
            guard !wantsPlayback else {
                return
            }

            await watchdog.cancel()

            let previous = reducer.state
            apply(.transportPaused)

            if previous != reducer.state,
               reducer.state == .paused {
                emit(.playbackPaused)
            }
        }
    }

    // MARK: - Public Intent Handling
    
    func handle(
        _ intent: PlayerIntent
    ) async throws {
        
        switch intent {
            
        case .load(let source):
            
            await watchdog.cancel()
            wantsPlayback = false
            apply(.loadStarted)
            
            currentSource = source
            
            do {
                try await player.load(
                    mediaId:
                        source.url.absoluteString,
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
            apply(.loadStarted)
            
            currentSource = source
            
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
            player.pause()
            
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
            player.stop()
            
            apply(.reset)
            
            emit(.stopped)
            
        case .release:
            
            await watchdog.cancel()
            wantsPlayback = false
            player.release()
            
            apply(.released)
            
            emit(.released)
            
        default:
            break
        }
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
        wantsPlayback = false

        switch error {
            
        case .network:
            
            apply(.networkLost)
            
            emit(.failed(error))
            
        default:
            
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
        apply(.networkLost)
    }
    
    func notifyRecoveryExhausted() async {
        await watchdog.cancel()
        wantsPlayback = false
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

private enum PlayerActorEvent {

    case ready

    case transportStatus(PlayerTransportStatus)

    case playbackCompleted
    
    case watchdogExpired

    case failed(PlayerError)

    case progress(PlaybackProgress)
}
