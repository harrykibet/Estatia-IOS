import Foundation

/// Defines when active video playback may survive an application background
/// transition. PiP does not authorize starting or resuming playback that was
/// already paused when the transition began.
enum BackgroundPlaybackPolicy {
    static func shouldKeepPlaybackActive(
        wasPlaying: Bool,
        isPictureInPictureActive: Bool
    ) -> Bool {
        wasPlaying && isPictureInPictureActive
    }
}
