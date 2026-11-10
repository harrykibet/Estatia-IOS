import Foundation

enum MediaSessionCommandResult: Equatable, Sendable {
    case success
    case unavailable
}

struct NowPlayingSnapshot: Equatable, Sendable {
    let title: String?
    let artist: String?
    let elapsedTime: TimeInterval
    let duration: TimeInterval?
    let playbackRate: Double
}

@MainActor
protocol MediaSessionProviding: AnyObject {
    func installCommandHandlers(
        onPlay: @escaping () -> MediaSessionCommandResult,
        onPause: @escaping () -> MediaSessionCommandResult,
        onTogglePlayback: @escaping () -> MediaSessionCommandResult,
        onSeek: @escaping (TimeInterval) -> MediaSessionCommandResult
    )
    func publish(_ snapshot: NowPlayingSnapshot)
    func clear()
}

/// Owns the system-facing representation of the currently active player.
///
/// The coordinator is deliberately independent of MediaPlayer so its state
/// mapping and remote-command routing can be tested without an OS media
/// command center. The provider is the only platform-specific boundary.
@MainActor
final class MediaSessionCoordinator {
    private let provider: any MediaSessionProviding
    private var snapshot: NowPlayingSnapshot?

    init(provider: any MediaSessionProviding = MediaSessionProvider()) {
        self.provider = provider
    }

    func installCommands(
        onPlay: @escaping () -> MediaSessionCommandResult,
        onPause: @escaping () -> MediaSessionCommandResult,
        onTogglePlayback: @escaping () -> MediaSessionCommandResult,
        onSeek: @escaping (TimeInterval) -> MediaSessionCommandResult
    ) {
        provider.installCommandHandlers(
            onPlay: onPlay,
            onPause: onPause,
            onTogglePlayback: onTogglePlayback,
            onSeek: onSeek
        )
    }

    func activate(
        title: String?,
        artist: String?,
        state: PlayerState,
        currentTime: TimeInterval,
        duration: TimeInterval?
    ) {
        snapshot = NowPlayingSnapshot(
            title: title,
            artist: artist,
            elapsedTime: Self.validTime(currentTime),
            duration: Self.validDuration(duration),
            playbackRate: Self.playbackRate(for: state)
        )
        publish()
    }

    func updatePlayback(
        state: PlayerState,
        currentTime: TimeInterval,
        duration: TimeInterval?
    ) {
        guard let current = snapshot else { return }
        snapshot = NowPlayingSnapshot(
            title: current.title,
            artist: current.artist,
            elapsedTime: Self.validTime(currentTime),
            duration: Self.validDuration(duration),
            playbackRate: Self.playbackRate(for: state)
        )
        publish()
    }

    func updateProgress(
        currentTime: TimeInterval,
        duration: TimeInterval?
    ) {
        guard let current = snapshot else { return }
        snapshot = NowPlayingSnapshot(
            title: current.title,
            artist: current.artist,
            elapsedTime: Self.validTime(currentTime),
            duration: Self.validDuration(duration),
            playbackRate: current.playbackRate
        )
        publish()
    }

    func clear() {
        snapshot = nil
        provider.clear()
    }

    private func publish() {
        guard let snapshot else { return }
        provider.publish(snapshot)
    }

    private static func playbackRate(for state: PlayerState) -> Double {
        state == .playing ? 1 : 0
    }

    private static func validTime(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? max(0, value) : 0
    }

    private static func validDuration(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}
