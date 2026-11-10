import XCTest
@testable import CorePlayerEngine

final class BackgroundPlaybackPolicyTests: XCTestCase {
    func testActivePlaybackIsRetainedWhenPictureInPictureIsActive() {
        XCTAssertTrue(
            BackgroundPlaybackPolicy.shouldKeepPlaybackActive(
                wasPlaying: true,
                isPictureInPictureActive: true
            )
        )
    }

    func testPlaybackIsPausedWhenPictureInPictureIsInactive() {
        XCTAssertFalse(
            BackgroundPlaybackPolicy.shouldKeepPlaybackActive(
                wasPlaying: true,
                isPictureInPictureActive: false
            )
        )
    }

    func testPausedPlaybackIsNotResumedByPictureInPictureFlag() {
        XCTAssertFalse(
            BackgroundPlaybackPolicy.shouldKeepPlaybackActive(
                wasPlaying: false,
                isPictureInPictureActive: true
            )
        )
    }

    func testPausedPlaybackRemainsPausedWhenPictureInPictureIsInactive() {
        XCTAssertFalse(
            BackgroundPlaybackPolicy.shouldKeepPlaybackActive(
                wasPlaying: false,
                isPictureInPictureActive: false
            )
        )
    }
}
