//
//  PlayerEngine.swift
//  CorePlayerEngine
//

import Foundation

@MainActor
public protocol PlayerEngine: AnyObject {

    // MARK: - Lifecycle

    func load(_ source: MediaSource) async throws

    /// Loads media using its stable domain-level identity.
    func load(
        mediaId: String,
        source: MediaSource
    ) async throws

    func play() async throws

    func pause() async throws

    /// Temporarily pauses transport without discarding the user's desired
    /// playback state. Used for OS audio-focus interruptions such as calls.
    func pauseForAudioInterruption() async

    /// Ends an OS audio interruption. Resumption is allowed only when both
    /// the system and the still-current playback intent permit it.
    func resumeFromAudioInterruption(shouldResume: Bool) async throws

    func seek(to seconds: TimeInterval) async throws

    func stop() async throws

    func release() async throws
    
    /// Notifies the engine that external network connectivity was lost.
    func notifyNetworkLost() async

    /// Terminates an unsuccessful automatic recovery cycle.
    func notifyRecoveryExhausted() async

    /// Whether the user still intends playback to continue after recovery.
    var shouldResumeAfterInterruption: Bool { get async }

    /// Replaces the transport item without applying configuration auto-play.
    func loadForNetworkRecovery(
        mediaId: String,
        source: MediaSource
    ) async throws

    /// Publishes a sustained-bandwidth warning without changing transport state.
    func notifySustainedLowBandwidth(_ isSustained: Bool) async
    
    // MARK: - State

    var state: AsyncStream<PlayerState> { get }

    var events: AsyncStream<PlayerEvent> { get }

    /// Current sustained-bandwidth warning state, including before a UI subscriber attaches.
    var isSustainedLowBandwidth: Bool { get }
    
    var currentState: PlayerState { get async }

    // MARK: - Observability

    var currentTime: TimeInterval { get async }

    var duration: TimeInterval? { get async }
}

public extension PlayerEngine {

    var isSustainedLowBandwidth: Bool { false }

    /// Compatibility fallback for custom engines. The AVFoundation engine
    /// overrides this to preserve its actor-owned desired-playback intent.
    func pauseForAudioInterruption() async {
        try? await pause()
    }

    /// Compatibility fallback for custom engines. Engines with an explicit
    /// intent model should override this method.
    func resumeFromAudioInterruption(shouldResume: Bool) async throws {
        guard shouldResume else { return }
        try await play()
    }

    var shouldResumeAfterInterruption: Bool {
        get async {
            let state = await currentState
            return state == .playing || state == .buffering
        }
    }

    func loadForNetworkRecovery(
        mediaId: String,
        source: MediaSource
    ) async throws {
        try await load(mediaId: mediaId, source: source)
    }

    /// Existing custom engines may ignore the optional quality notification.
    func notifySustainedLowBandwidth(_ isSustained: Bool) async {}

    func load(
        mediaId: String,
        source: MediaSource
    ) async throws {
        try await load(source)
    }
}
