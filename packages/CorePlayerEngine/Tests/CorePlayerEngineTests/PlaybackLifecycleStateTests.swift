import XCTest
@testable import CorePlayerEngine

final class PlaybackLifecycleStateTests: XCTestCase {

    func testPreviouslyPlayingItemGetsOneForegroundResumeIntent() {
        var state = PlaybackLifecycleState()

        let backgroundGeneration = state.beginBackgroundTransition()
        XCTAssertTrue(
            state.recordBackgroundPlayback(
                wasPlaying: true,
                generation: backgroundGeneration
            )
        )

        let foreground = state.beginForegroundTransition()
        XCTAssertTrue(foreground.shouldResume)
        XCTAssertTrue(state.isCurrent(foreground.generation))

        let duplicateForeground = state.beginForegroundTransition()
        XCTAssertFalse(duplicateForeground.shouldResume)
        XCTAssertEqual(duplicateForeground.generation, foreground.generation)
        XCTAssertTrue(state.isCurrent(foreground.generation))

        state.finishForegroundResume(generation: foreground.generation)
        let laterForeground = state.beginForegroundTransition()
        XCTAssertFalse(laterForeground.shouldResume)
    }

    func testPreviouslyPausedItemDoesNotGetForegroundResumeIntent() {
        var state = PlaybackLifecycleState()

        let backgroundGeneration = state.beginBackgroundTransition()
        XCTAssertTrue(
            state.recordBackgroundPlayback(
                wasPlaying: false,
                generation: backgroundGeneration
            )
        )

        let foreground = state.beginForegroundTransition()
        XCTAssertFalse(foreground.shouldResume)
    }

    func testExplicitPauseInvalidatesPendingBackgroundSnapshot() {
        var state = PlaybackLifecycleState()

        let backgroundGeneration = state.beginBackgroundTransition()
        let pauseGeneration = state.invalidateForExplicitCommand()

        XCTAssertFalse(state.isCurrent(backgroundGeneration))
        XCTAssertFalse(
            state.recordBackgroundPlayback(
                wasPlaying: true,
                generation: backgroundGeneration
            )
        )
        XCTAssertTrue(state.isCurrent(pauseGeneration))
        XCTAssertFalse(state.beginForegroundTransition().shouldResume)
    }

    func testNewPlayRequestInvalidatesPendingBackgroundSnapshot() {
        var state = PlaybackLifecycleState()

        let backgroundGeneration = state.beginBackgroundTransition()
        let playGeneration = state.invalidateForExplicitCommand()

        XCTAssertFalse(
            state.recordBackgroundPlayback(
                wasPlaying: true,
                generation: backgroundGeneration
            )
        )
        XCTAssertTrue(state.isCurrent(playGeneration))
        XCTAssertFalse(state.beginForegroundTransition().shouldResume)
    }


    func testExplicitPauseAfterCaptureClearsPreviouslyActiveResumeIntent() {
        var state = PlaybackLifecycleState()

        let backgroundGeneration = state.beginBackgroundTransition()
        XCTAssertTrue(
            state.recordBackgroundPlayback(
                wasPlaying: true,
                generation: backgroundGeneration
            )
        )

        let pauseGeneration = state.invalidateForExplicitCommand()
        XCTAssertFalse(state.isCurrent(backgroundGeneration))
        XCTAssertTrue(state.isCurrent(pauseGeneration))
        XCTAssertFalse(state.beginForegroundTransition().shouldResume)
    }

    func testForegroundBeforeBackgroundSnapshotCompletesDiscardsStaleSnapshot() {
        var state = PlaybackLifecycleState()

        let backgroundGeneration = state.beginBackgroundTransition()
        let foreground = state.beginForegroundTransition()

        XCTAssertFalse(foreground.shouldResume)
        XCTAssertFalse(
            state.recordBackgroundPlayback(
                wasPlaying: true,
                generation: backgroundGeneration
            )
        )
    }

    func testDuplicateBackgroundNotificationsShareOneCaptureGeneration() {
        var state = PlaybackLifecycleState()

        let first = state.beginBackgroundTransition()
        let duplicate = state.beginBackgroundTransition()

        XCTAssertEqual(first, duplicate)
        XCTAssertTrue(
            state.recordBackgroundPlayback(
                wasPlaying: true,
                generation: first
            )
        )
    }

    func testExplicitCommandInvalidatesInFlightForegroundResume() {
        var state = PlaybackLifecycleState()

        let backgroundGeneration = state.beginBackgroundTransition()
        XCTAssertTrue(
            state.recordBackgroundPlayback(
                wasPlaying: true,
                generation: backgroundGeneration
            )
        )

        let foreground = state.beginForegroundTransition()
        XCTAssertTrue(foreground.shouldResume)

        let pauseGeneration = state.invalidateForExplicitCommand()
        state.finishForegroundResume(generation: foreground.generation)

        XCTAssertFalse(state.isCurrent(foreground.generation))
        XCTAssertTrue(state.isCurrent(pauseGeneration))
        XCTAssertFalse(state.beginForegroundTransition().shouldResume)
    }
}
