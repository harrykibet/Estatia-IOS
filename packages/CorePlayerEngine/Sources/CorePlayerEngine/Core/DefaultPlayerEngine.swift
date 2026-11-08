//
//  DefaultPlayerEngine.swift
//  CorePlayerEngine
//
//  Created by builder on 9/18/26.
//

import Foundation
import AVFoundation

@MainActor
final class DefaultPlayerEngine: PlayerEngine, AVPlayerProviding {
    
    private let actor: PlayerActor
    private let presentationTransport: AVPlayerWrapper
    
    private let stateEmitter = PlayerEventEmitter<PlayerState>()
    private let eventEmitter = PlayerEventEmitter<PlayerEvent>()
    
    init(
        config: PlayerConfiguration,
        player: AVPlayerWrapper,
        watchdog: PlaybackWatchdog
    ) {
        self.presentationTransport = player
        self.actor = PlayerActor(
            config: config,
            player: player,
            watchdog: watchdog,
            stateEmitter: stateEmitter,
            eventEmitter: eventEmitter
        )
    }
    
    // MARK: - Presentation

    var presentationPlayer: AVPlayer? {
        presentationTransport.presentationPlayer()
    }

    var observedBitrateBps: Double? {
        presentationTransport.observedBitrateBps()
    }

    func setPreferredPeakBitRate(_ bitrateBps: Double) {
        presentationTransport.setPreferredPeakBitRate(bitrateBps)
    }

    // MARK: - Streams
    
    var state: AsyncStream<PlayerState> {
        stateEmitter.stream
    }
    
    var currentState: PlayerState {
        get async {
            await actor.currentState
        }
    }
    
    var events: AsyncStream<PlayerEvent> {
        eventEmitter.stream
    }
    
    // MARK: - Lifecycle
    
    func load(_ source: MediaSource) async throws {
        try await actor.handle(.load(source))
    }

    func load(
        mediaId: String,
        source: MediaSource
    ) async throws {
        try await actor.handle(
            .loadIdentified(
                mediaId: mediaId,
                source: source
            )
        )
    }
    
    func play() async throws {
        try await actor.handle(.play)
    }
    
    func pause() async throws {
        try await actor.handle(.pause)
    }
    
    func seek(to seconds: TimeInterval) async throws {
        try await actor.handle(.seek(seconds))
    }
    
    func stop() async throws {
        try await actor.handle(.stop)
    }
    
    func release() async throws {
        try await actor.handle(.release)
    }
    
    // MARK: - Observability
    
    var currentTime: TimeInterval {
        get async {
            await actor.currentTime
        }
    }
    
    var duration: TimeInterval? {
        get async {
            await actor.duration
        }
    }
    
    // MARK: - Network
    
    func notifyNetworkLost() async {
        await actor.notifyNetworkLost()
    }
    
    func notifyRecoveryExhausted() async {
        await actor.notifyRecoveryExhausted()
    }
}
