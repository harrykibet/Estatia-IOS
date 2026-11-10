import Foundation
import MediaPlayer

/// MediaPlayer adapter for Now Playing metadata and lock-screen/Control
/// Center commands. All mutations are owned by the main actor.
@MainActor
final class MediaSessionProvider: MediaSessionProviding {
    private let commandCenter: MPRemoteCommandCenter
    private let nowPlayingCenter: MPNowPlayingInfoCenter

    private var onPlay: (() -> MediaSessionCommandResult)?
    private var onPause: (() -> MediaSessionCommandResult)?
    private var onTogglePlayback: (() -> MediaSessionCommandResult)?
    private var onSeek: ((TimeInterval) -> MediaSessionCommandResult)?

    private var commandTargets: [(command: MPRemoteCommand, token: Any)] = []

    init(
        commandCenter: MPRemoteCommandCenter = .shared(),
        nowPlayingCenter: MPNowPlayingInfoCenter = .default()
    ) {
        self.commandCenter = commandCenter
        self.nowPlayingCenter = nowPlayingCenter
    }

    func installCommandHandlers(
        onPlay: @escaping () -> MediaSessionCommandResult,
        onPause: @escaping () -> MediaSessionCommandResult,
        onTogglePlayback: @escaping () -> MediaSessionCommandResult,
        onSeek: @escaping (TimeInterval) -> MediaSessionCommandResult
    ) {
        removeCommandTargets()

        self.onPlay = onPlay
        self.onPause = onPause
        self.onTogglePlayback = onTogglePlayback
        self.onSeek = onSeek

        let playToken = commandCenter.playCommand.addTarget { [weak self] _ in
            Self.performOnMainActor {
                self?.onPlay?() ?? .unavailable
            }
        }
        commandTargets.append((commandCenter.playCommand, playToken))

        let pauseToken = commandCenter.pauseCommand.addTarget { [weak self] _ in
            Self.performOnMainActor {
                self?.onPause?() ?? .unavailable
            }
        }
        commandTargets.append((commandCenter.pauseCommand, pauseToken))

        let toggleToken = commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Self.performOnMainActor {
                self?.onTogglePlayback?() ?? .unavailable
            }
        }
        commandTargets.append((commandCenter.togglePlayPauseCommand, toggleToken))

        let seekToken = commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            return Self.performOnMainActor {
                self?.onSeek?(event.positionTime) ?? .unavailable
            }
        }
        commandTargets.append((commandCenter.changePlaybackPositionCommand, seekToken))

        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true
    }

    func publish(_ snapshot: NowPlayingSnapshot) {
        var info: [String: Any] = [:]
        if let title = snapshot.title, !title.isEmpty {
            info[MPMediaItemPropertyTitle] = title
        }
        if let artist = snapshot.artist, !artist.isEmpty {
            info[MPMediaItemPropertyArtist] = artist
        }

        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = snapshot.elapsedTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = snapshot.playbackRate
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        if let duration = snapshot.duration {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }

        nowPlayingCenter.nowPlayingInfo = info
        nowPlayingCenter.playbackState = snapshot.playbackRate > 0 ? .playing : .paused
    }

    func clear() {
        removeCommandTargets()
        onPlay = nil
        onPause = nil
        onTogglePlayback = nil
        onSeek = nil
        nowPlayingCenter.nowPlayingInfo = nil
        nowPlayingCenter.playbackState = .stopped
    }

    private func removeCommandTargets() {
        for target in commandTargets {
            target.command.removeTarget(target.token)
        }
        commandTargets.removeAll(keepingCapacity: false)

        // MPRemoteCommandCenter is process-wide. Do not disable shared
        // commands during teardown because another audio owner may have
        // installed its own handlers on the same command center.
    }

    private static func performOnMainActor(
        _ action: @MainActor () -> MediaSessionCommandResult
    ) -> MPRemoteCommandHandlerStatus {
        guard Thread.isMainThread else {
            return .commandFailed
        }

        let result = MainActor.assumeIsolated(action)
        switch result {
        case .success:
            return .success
        case .unavailable:
            return .commandFailed
        }
    }
}
