import Foundation
import XCTest
@testable import CorePlayerEngine

@MainActor
final class PlayerActorTests: XCTestCase {

    private final class FakePlayerTransport:
        PlayerTransport,
        @unchecked Sendable {

        private let lock = NSLock()

        private var readyHandler: (@MainActor @Sendable () -> Void)?
        private var transportHandler:
            (@MainActor @Sendable (PlayerTransportStatus) -> Void)?
        private var completionHandler: (@MainActor @Sendable () -> Void)?
        private var errorHandler: (@MainActor @Sendable (Error) -> Void)?
        private var progressHandler:
            (@MainActor @Sendable (PlaybackProgress) -> Void)?

        private var _playCount = 0
        private var _pauseCount = 0
        private var _loadCount = 0

        var onReady: (@MainActor @Sendable () -> Void)? {
            get { withLock { readyHandler } }
            set { withLock { readyHandler = newValue } }
        }

        var onTransportStatus:
            (@MainActor @Sendable (PlayerTransportStatus) -> Void)? {
            get { withLock { transportHandler } }
            set { withLock { transportHandler = newValue } }
        }

        var onCompletion: (@MainActor @Sendable () -> Void)? {
            get { withLock { completionHandler } }
            set { withLock { completionHandler = newValue } }
        }

        var onError: (@MainActor @Sendable (Error) -> Void)? {
            get { withLock { errorHandler } }
            set { withLock { errorHandler = newValue } }
        }

        var onProgress:
            (@MainActor @Sendable (PlaybackProgress) -> Void)? {
            get { withLock { progressHandler } }
            set { withLock { progressHandler = newValue } }
        }

        var playCount: Int { withLock { _playCount } }
        var pauseCount: Int { withLock { _pauseCount } }
        var loadCount: Int { withLock { _loadCount } }

        func load(mediaId: String, source: MediaSource) async throws {
            withLock { _loadCount += 1 }
        }

        func play() {
            withLock { _playCount += 1 }
        }

        func pause() {
            withLock { _pauseCount += 1 }
        }

        func stop() {}

        func seek(to seconds: TimeInterval) async throws {}

        func release() {}

        @MainActor
        func emitReady() {
            let handler = withLock { readyHandler }
            handler?()
        }

        @MainActor
        func emitTransportStatus(_ status: PlayerTransportStatus) {
            let handler = withLock { transportHandler }
            handler?(status)
        }

        private func withLock<T>(_ operation: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return operation()
        }
    }

    func testPlaybackStateChangesOnlyAfterObservedTransportStatus() async throws {
        let transport = FakePlayerTransport()
        let stateEmitter = PlayerEventEmitter<PlayerState>()
        let eventEmitter = PlayerEventEmitter<PlayerEvent>()

        let actor = PlayerActor(
            config: PlayerConfiguration(),
            player: transport,
            watchdog: PlaybackWatchdog(),
            stateEmitter: stateEmitter,
            eventEmitter: eventEmitter
        )

        var states = stateEmitter.stream.makeAsyncIterator()

        let source = MediaSource(
            url: URL(string: "https://example.com/video.mp4")!
        )

        try await actor.handle(
            .loadIdentified(
                mediaId: "video-1",
                source: source
            )
        )
        let loadingState = await states.next()
        XCTAssertEqual(loadingState, .loading)

        transport.emitReady()
        let readyState = await states.next()
        XCTAssertEqual(readyState, .ready)

        try await actor.handle(.play)

        XCTAssertEqual(transport.playCount, 1)
        let stateAfterPlayRequest = await actor.currentState
        XCTAssertEqual(stateAfterPlayRequest, .ready)

        transport.emitTransportStatus(.waiting)
        let bufferingState = await states.next()
        XCTAssertEqual(bufferingState, .buffering)

        transport.emitTransportStatus(.playing)
        let playingState = await states.next()
        XCTAssertEqual(playingState, .playing)
        let currentPlayingState = await actor.currentState
        XCTAssertEqual(currentPlayingState, .playing)

        try await actor.handle(.pause)

        XCTAssertEqual(transport.pauseCount, 1)
        let stateAfterPauseRequest = await actor.currentState
        XCTAssertEqual(stateAfterPauseRequest, .playing)

        transport.emitTransportStatus(.paused)
        let pausedState = await states.next()
        XCTAssertEqual(pausedState, .paused)
        let currentPausedState = await actor.currentState
        XCTAssertEqual(currentPausedState, .paused)

        try await actor.handle(.release)
    }

    func testPauseDuringBufferingWaitsForPausedTransportConfirmation() async throws {
        let transport = FakePlayerTransport()
        let stateEmitter = PlayerEventEmitter<PlayerState>()
        let actor = PlayerActor(
            config: PlayerConfiguration(),
            player: transport,
            watchdog: PlaybackWatchdog(),
            stateEmitter: stateEmitter,
            eventEmitter: PlayerEventEmitter<PlayerEvent>()
        )

        var states = stateEmitter.stream.makeAsyncIterator()
        let source = MediaSource(
            url: URL(string: "https://example.com/video.mp4")!
        )

        try await actor.handle(.load(source))
        let loadingState = await states.next()
        XCTAssertEqual(loadingState, .loading)

        transport.emitReady()
        let readyState = await states.next()
        XCTAssertEqual(readyState, .ready)

        try await actor.handle(.play)
        transport.emitTransportStatus(.waiting)
        let bufferingState = await states.next()
        XCTAssertEqual(bufferingState, .buffering)

        try await actor.handle(.pause)
        let stateAfterBufferingPauseRequest = await actor.currentState
        XCTAssertEqual(stateAfterBufferingPauseRequest, .buffering)

        transport.emitTransportStatus(.paused)
        let pausedState = await states.next()
        XCTAssertEqual(pausedState, .paused)

        await actor.handle(.release)
    }
}
