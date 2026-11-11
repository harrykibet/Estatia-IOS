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
            (@Sendable (PlayerTransportStatus) -> Void)?
        private var completionHandler: (@MainActor @Sendable () -> Void)?
        private var errorHandler: (@MainActor @Sendable (Error) -> Void)?
        private var progressHandler:
            (@MainActor @Sendable (PlaybackProgress) -> Void)?

        private var _playCount = 0
        private var _pauseCount = 0
        private var _loadCount = 0
        private var _loadedMediaIds: [String] = []
        private var _loadedSources: [MediaSource] = []

        var onReady: (@MainActor @Sendable () -> Void)? {
            get { withLock { readyHandler } }
            set { withLock { readyHandler = newValue } }
        }

        var onTransportStatus:
            (@Sendable (PlayerTransportStatus) -> Void)? {
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
        var loadedMediaIds: [String] { withLock { _loadedMediaIds } }
        var loadedSources: [MediaSource] { withLock { _loadedSources } }

        func load(mediaId: String, source: MediaSource) async throws {
            withLock {
                _loadCount += 1
                _loadedMediaIds.append(mediaId)
                _loadedSources.append(source)
            }
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

        @MainActor
        func emitFailure(_ error: Error) {
            let handler = withLock { errorHandler }
            handler?(error)
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
        var events = eventEmitter.stream.makeAsyncIterator()

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
        let readyEvent = await events.next()
        if case .ready? = readyEvent {
        } else {
            XCTFail("Expected ready event")
        }

        try await actor.handle(.play)

        XCTAssertEqual(transport.playCount, 1)
        let stateAfterPlayRequest = await actor.currentState
        XCTAssertEqual(stateAfterPlayRequest, .ready)

        transport.emitTransportStatus(.waiting)
        let bufferingState = await states.next()
        XCTAssertEqual(bufferingState, .buffering)
        let bufferingStartedEvent = await events.next()
        if case .bufferingStarted? = bufferingStartedEvent {
        } else {
            XCTFail("Expected bufferingStarted event")
        }

        transport.emitTransportStatus(.playing)
        let playingState = await states.next()
        XCTAssertEqual(playingState, .playing)
        let bufferingEndedEvent = await events.next()
        if case .bufferingEnded? = bufferingEndedEvent {
        } else {
            XCTFail("Expected bufferingEnded event before playbackStarted")
        }
        let playbackStartedEvent = await events.next()
        if case .playbackStarted? = playbackStartedEvent {
        } else {
            XCTFail("Expected playbackStarted event")
        }
        let currentPlayingState = await actor.currentState
        XCTAssertEqual(currentPlayingState, .playing)

        try await actor.handle(.pause)

        XCTAssertEqual(transport.pauseCount, 1)
        let stateAfterPauseRequest = await actor.currentState
        XCTAssertEqual(stateAfterPauseRequest, .playing)

        transport.emitTransportStatus(.paused)
        let pausedState = await states.next()
        XCTAssertEqual(pausedState, .paused)
        let playbackPausedEvent = await events.next()
        if case .playbackPaused? = playbackPausedEvent {
        } else {
            XCTFail("Expected playbackPaused event")
        }
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

        try await actor.handle(.release)
    }

    func testNetworkLossUsesLatestPauseIntentWhileBuffering() async throws {
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

        // Intent changes immediately, before AVPlayer confirms the paused state.
        try await actor.handle(.pause)
        let resumeIntentBeforeNetworkLoss = await actor.shouldResumeAfterInterruption
        XCTAssertFalse(resumeIntentBeforeNetworkLoss)

        await actor.notifyNetworkLost()

        let reconnectingState = await states.next()
        XCTAssertEqual(reconnectingState, .reconnecting)
        let resumeIntentAfterNetworkLoss = await actor.shouldResumeAfterInterruption
        XCTAssertFalse(resumeIntentAfterNetworkLoss)

        try await actor.handle(.release)
    }

    func testNetworkRecoveryLoadWaitsForAuthorizedResumeAndSuppressesAutoPlay()
        async throws {
        let transport = FakePlayerTransport()
        let stateEmitter = PlayerEventEmitter<PlayerState>()
        let actor = PlayerActor(
            config: PlayerConfiguration(autoPlay: true),
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
        let initialLoadingState = await states.next()
        XCTAssertEqual(initialLoadingState, .loading)

        transport.emitReady()
        let initialReadyState = await states.next()
        XCTAssertEqual(initialReadyState, .ready)
        XCTAssertEqual(transport.playCount, 1)

        await actor.notifyNetworkLost()
        let reconnectingState = await states.next()
        XCTAssertEqual(reconnectingState, .reconnecting)

        try await actor.loadForNetworkRecovery(
            mediaId: "video-1",
            source: source
        )
        let recoveryLoadingState = await states.next()
        XCTAssertEqual(recoveryLoadingState, .loading)

        transport.emitReady()
        let recoveryReadyState = await states.next()
        XCTAssertEqual(recoveryReadyState, .ready)

        XCTAssertEqual(
            transport.playCount,
            1,
            "Recovery must not auto-play before the orchestrator validates the attempt."
        )

        try await actor.handle(.play)
        XCTAssertEqual(transport.playCount, 2)

        try await actor.handle(.release)
    }

    func testAudioInterruptionPausesTransportButPreservesPlaybackIntent() async throws {
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
            url: URL(string: "https://example.com/interruption.mp4")!
        )

        try await actor.handle(.load(source))
        _ = await states.next()
        transport.emitReady()
        _ = await states.next()
        try await actor.handle(.play)
        let intentAfterPlay = await actor.shouldResumeAfterInterruption
        XCTAssertTrue(intentAfterPlay)

        transport.emitTransportStatus(.playing)
        let playingState = await states.next()
        XCTAssertEqual(playingState, .playing)

        try await actor.handle(.audioInterruptionBegan)
        XCTAssertEqual(transport.pauseCount, 1)
        let intentDuringInterruption = await actor.shouldResumeAfterInterruption
        XCTAssertTrue(intentDuringInterruption)

        transport.emitTransportStatus(.paused)
        let pausedState = await states.next()
        XCTAssertEqual(pausedState, .paused)
        let currentPausedState = await actor.currentState
        XCTAssertEqual(currentPausedState, .paused)

        try await actor.handle(.audioInterruptionEnded(shouldResume: true))
        XCTAssertEqual(transport.playCount, 2)
        let intentAfterInterruption = await actor.shouldResumeAfterInterruption
        XCTAssertTrue(intentAfterInterruption)

        transport.emitTransportStatus(.playing)
        let resumedState = await states.next()
        XCTAssertEqual(resumedState, .playing)
        try await actor.handle(.release)
    }

    func testExplicitPauseDuringAudioInterruptionCancelsAutomaticResume() async throws {
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
            url: URL(string: "https://example.com/interruption-pause.mp4")!
        )

        try await actor.handle(.load(source))
        _ = await states.next()
        transport.emitReady()
        _ = await states.next()
        try await actor.handle(.play)
        transport.emitTransportStatus(.playing)
        _ = await states.next()

        try await actor.handle(.audioInterruptionBegan)
        transport.emitTransportStatus(.paused)
        let interruptedPausedState = await states.next()
        XCTAssertEqual(interruptedPausedState, .paused)
        let resumeIntentDuringInterruption = await actor.shouldResumeAfterInterruption
        XCTAssertTrue(resumeIntentDuringInterruption)

        // This is a user command, not another system pause. It must replace
        // the saved resume intent even while the interruption is still active.
        try await actor.handle(.pause)
        let intentAfterExplicitPause = await actor.shouldResumeAfterInterruption
        XCTAssertFalse(intentAfterExplicitPause)

        try await actor.handle(.audioInterruptionEnded(shouldResume: true))
        XCTAssertEqual(transport.playCount, 1)
        let intentAfterInterruption = await actor.shouldResumeAfterInterruption
        XCTAssertFalse(intentAfterInterruption)
        let finalPausedState = await actor.currentState
        XCTAssertEqual(finalPausedState, .paused)
        try await actor.handle(.release)
    }

    func testAudioInterruptionWithoutSystemResumeClearsPlaybackIntent() async throws {
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
            url: URL(string: "https://example.com/interruption-no-resume.mp4")!
        )

        try await actor.handle(.load(source))
        _ = await states.next()
        transport.emitReady()
        _ = await states.next()
        try await actor.handle(.play)
        transport.emitTransportStatus(.playing)
        _ = await states.next()

        try await actor.handle(.audioInterruptionBegan)
        transport.emitTransportStatus(.paused)
        _ = await states.next()

        try await actor.handle(.audioInterruptionEnded(shouldResume: false))

        XCTAssertEqual(transport.playCount, 1)
        let intentAfterSystemDeclinedResume = await actor.shouldResumeAfterInterruption
        XCTAssertFalse(intentAfterSystemDeclinedResume)
        let finalPausedState = await actor.currentState
        XCTAssertEqual(finalPausedState, .paused)
        try await actor.handle(.release)
    }

    func testPlayRequestedDuringAudioInterruptionIsDeferredUntilItEnds() async throws {
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
            url: URL(string: "https://example.com/interruption-deferred-play.mp4")!
        )

        try await actor.handle(.load(source))
        _ = await states.next()
        transport.emitReady()
        let readyState = await states.next()
        XCTAssertEqual(readyState, .ready)

        try await actor.handle(.audioInterruptionBegan)
        try await actor.handle(.play)
        XCTAssertEqual(
            transport.playCount,
            0,
            "A play request must not reach AVPlayer while the audio session is interrupted."
        )
        let requestedPlaybackIntent = await actor.shouldResumeAfterInterruption
        XCTAssertTrue(requestedPlaybackIntent)

        try await actor.handle(.audioInterruptionEnded(shouldResume: true))
        XCTAssertEqual(transport.playCount, 1)

        transport.emitTransportStatus(.playing)
        let playingState = await states.next()
        XCTAssertEqual(playingState, .playing)
        try await actor.handle(.release)
    }


    func testDecoderFailureRetriesSameMediaWithBaselineAndResumesPlayback() async throws {
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
            url: URL(string: "https://media.estatia.com/watch/master.m3u8?token=abc")!
        )

        try await actor.handle(
            .loadIdentified(mediaId: "video-baseline", source: source)
        )
        XCTAssertEqual(await states.next(), .loading)

        transport.emitReady()
        XCTAssertEqual(await states.next(), .ready)

        try await actor.handle(.play)
        XCTAssertEqual(transport.playCount, 1)
        transport.emitTransportStatus(.playing)
        XCTAssertEqual(await states.next(), .playing)

        transport.emitFailure(
            NSError(
                domain: AVError.errorDomain,
                code: AVError.Code.decoderNotFound.rawValue
            )
        )

        XCTAssertEqual(await states.next(), .loading)
        XCTAssertEqual(transport.loadCount, 2)
        XCTAssertEqual(transport.loadedMediaIds.last, "video-baseline")

        let fallbackSource = try XCTUnwrap(transport.loadedSources.last)
        let fallbackComponents = try XCTUnwrap(
            URLComponents(url: fallbackSource.url, resolvingAgainstBaseURL: false)
        )
        XCTAssertEqual(
            fallbackComponents.queryItems?.first(where: { $0.name == "codec" })?.value,
            "baseline"
        )
        XCTAssertEqual(
            fallbackComponents.queryItems?.first(where: { $0.name == "token" })?.value,
            "abc"
        )

        // The baseline rendition must become ready before the original
        // playback intent is allowed to reach the transport again.
        XCTAssertEqual(transport.playCount, 1)
        transport.emitReady()
        XCTAssertEqual(await states.next(), .ready)
        XCTAssertEqual(transport.playCount, 2)

        transport.emitTransportStatus(.playing)
        XCTAssertEqual(await states.next(), .playing)
        XCTAssertTrue(await actor.shouldResumeAfterInterruption)

        try await actor.handle(.release)
    }

    func testExplicitPauseDuringBaselineLoadCancelsAutomaticResume() async throws {
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
            url: URL(string: "https://media.estatia.com/watch/master.m3u8?codec=hevc")!
        )

        try await actor.handle(
            .loadIdentified(mediaId: "video-paused", source: source)
        )
        _ = await states.next()
        transport.emitReady()
        _ = await states.next()
        try await actor.handle(.play)
        transport.emitTransportStatus(.playing)
        _ = await states.next()

        transport.emitFailure(
            NSError(
                domain: AVError.errorDomain,
                code: AVError.Code.decoderTemporarilyUnavailable.rawValue
            )
        )
        XCTAssertEqual(await states.next(), .loading)
        XCTAssertEqual(transport.loadCount, 2)

        try await actor.handle(.pause)
        XCTAssertFalse(await actor.shouldResumeAfterInterruption)

        transport.emitReady()
        XCTAssertEqual(await states.next(), .ready)
        XCTAssertEqual(
            transport.playCount,
            1,
            "A user pause during fallback loading must suppress automatic resume."
        )

        try await actor.handle(.release)
    }

    func testBaselineDecoderFailureIsTerminalAndDoesNotRetryAgain() async throws {
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
            url: URL(string: "https://media.estatia.com/watch/master.m3u8?codec=av1")!
        )

        try await actor.handle(
            .loadIdentified(mediaId: "video-terminal", source: source)
        )
        _ = await states.next()
        transport.emitReady()
        _ = await states.next()
        try await actor.handle(.play)

        transport.emitFailure(
            NSError(
                domain: AVError.errorDomain,
                code: AVError.Code.decoderNotFound.rawValue
            )
        )
        XCTAssertEqual(await states.next(), .loading)
        XCTAssertEqual(transport.loadCount, 2)

        // The second failure belongs to the Baseline request; never start
        // another retry cycle for the same managed media item.
        transport.emitFailure(
            NSError(
                domain: AVError.errorDomain,
                code: AVError.Code.decoderNotFound.rawValue
            )
        )
        XCTAssertEqual(
            await states.next(),
            .error(.decoderUnavailable)
        )
        XCTAssertEqual(transport.loadCount, 2)

        try await actor.handle(.release)
    }

    func testDecoderFailureForExternalMediaDoesNotRewriteItsURL() async throws {
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
            url: URL(string: "https://video.example.net/watch/master.m3u8?token=abc")!
        )

        try await actor.handle(
            .loadIdentified(mediaId: "external-video", source: source)
        )
        _ = await states.next()
        transport.emitReady()
        _ = await states.next()
        try await actor.handle(.play)

        transport.emitFailure(
            NSError(
                domain: AVError.errorDomain,
                code: AVError.Code.decoderNotFound.rawValue
            )
        )
        XCTAssertEqual(
            await states.next(),
            .error(.decoderUnavailable)
        )
        XCTAssertEqual(transport.loadCount, 1)

        try await actor.handle(.release)
    }


}
