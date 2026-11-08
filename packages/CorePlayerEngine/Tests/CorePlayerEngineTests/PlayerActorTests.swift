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

        func emitReady() {
            let handler = withLock { readyHandler }
            handler?()
        }

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
        XCTAssertEqual(await states.next(), .loading)

        transport.emitReady()
        XCTAssertEqual(await states.next(), .ready)

        try await actor.handle(.play)

        XCTAssertEqual(transport.playCount, 1)
        XCTAssertEqual(await actor.currentState, .ready)

        transport.emitTransportStatus(.waiting)
        XCTAssertEqual(await states.next(), .buffering)

        transport.emitTransportStatus(.playing)
        XCTAssertEqual(await states.next(), .playing)
        XCTAssertEqual(await actor.currentState, .playing)

        try await actor.handle(.pause)

        XCTAssertEqual(transport.pauseCount, 1)
        XCTAssertEqual(await actor.currentState, .playing)

        transport.emitTransportStatus(.paused)
        XCTAssertEqual(await states.next(), .paused)
        XCTAssertEqual(await actor.currentState, .paused)

        await actor.handle(.release)
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
        XCTAssertEqual(await states.next(), .loading)

        transport.emitReady()
        XCTAssertEqual(await states.next(), .ready)

        try await actor.handle(.play)
        transport.emitTransportStatus(.waiting)
        XCTAssertEqual(await states.next(), .buffering)

        try await actor.handle(.pause)
        XCTAssertEqual(await actor.currentState, .buffering)

        transport.emitTransportStatus(.paused)
        XCTAssertEqual(await states.next(), .paused)

        await actor.handle(.release)
    }
}
