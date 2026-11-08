import Foundation

/// Internal playback transport boundary consumed by PlayerActor.
///
/// AVPlayerWrapper is the production adapter. Tests use a deterministic fake
/// so command acceptance can be distinguished from observed transport changes.
protocol PlayerTransport: AnyObject, Sendable {
    var onReady: (@MainActor @Sendable () -> Void)? { get set }
    var onTransportStatus: (@Sendable (PlayerTransportStatus) -> Void)? { get set }
    var onCompletion: (@MainActor @Sendable () -> Void)? { get set }
    var onError: (@MainActor @Sendable (Error) -> Void)? { get set }
    var onProgress: (@MainActor @Sendable (PlaybackProgress) -> Void)? { get set }

    func load(mediaId: String, source: MediaSource) async throws
    func play()
    func pause()
    func stop()
    func seek(to seconds: TimeInterval) async throws
    func release()
}
