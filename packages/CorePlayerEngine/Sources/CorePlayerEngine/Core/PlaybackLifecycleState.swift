import Foundation

/// Tracks whether playback may be resumed after an application lifecycle
/// transition. Generations invalidate asynchronous observations when a newer
/// user command or lifecycle event takes ownership.
struct PlaybackLifecycleState: Sendable {

    private enum Phase: Sendable {
        case foreground
        case backgroundCapturePending
        case backgrounded(shouldResume: Bool)
        case foregroundResumePending
    }

    private(set) var generation: UInt64 = 0
    private var phase: Phase = .foreground

    var isBackgrounded: Bool {
        switch phase {
        case .backgroundCapturePending, .backgrounded:
            return true
        case .foreground, .foregroundResumePending:
            return false
        }
    }

    /// Starts one background capture. Duplicate background notifications
    /// while the same transition is pending or complete are idempotent.
    mutating func beginBackgroundTransition() -> UInt64 {
        guard !isBackgrounded else {
            return generation
        }

        generation &+= 1
        phase = .backgroundCapturePending
        return generation
    }

    /// Commits the asynchronous playback snapshot only if no newer operation
    /// has invalidated the background transition.
    @discardableResult
    mutating func recordBackgroundPlayback(
        wasPlaying: Bool,
        generation expectedGeneration: UInt64
    ) -> Bool {
        guard generation == expectedGeneration,
              case .backgroundCapturePending = phase
        else {
            return false
        }

        phase = .backgrounded(shouldResume: wasPlaying)
        return true
    }

    /// Consumes the background resume intent exactly once. A duplicate
    /// foreground notification must not invalidate a resume already underway.
    mutating func beginForegroundTransition()
        -> (generation: UInt64, shouldResume: Bool) {
        switch phase {
        case .backgroundCapturePending:
            // Foreground returned before the background snapshot completed.
            // Invalidate that stale snapshot rather than guessing playback intent.
            generation &+= 1
            phase = .foreground
            return (generation, false)

        case let .backgrounded(shouldResume):
            generation &+= 1
            phase = shouldResume ? .foregroundResumePending : .foreground
            return (generation, shouldResume)

        case .foreground, .foregroundResumePending:
            return (generation, false)
        }
    }

    /// Explicit play/pause commands supersede lifecycle-driven intent.
    @discardableResult
    mutating func invalidateForExplicitCommand() -> UInt64 {
        generation &+= 1
        phase = .foreground
        return generation
    }

    func isCurrent(_ expectedGeneration: UInt64) -> Bool {
        generation == expectedGeneration
    }

    mutating func finishForegroundResume(
        generation expectedGeneration: UInt64
    ) {
        guard generation == expectedGeneration,
              case .foregroundResumePending = phase
        else {
            return
        }

        phase = .foreground
    }
}
