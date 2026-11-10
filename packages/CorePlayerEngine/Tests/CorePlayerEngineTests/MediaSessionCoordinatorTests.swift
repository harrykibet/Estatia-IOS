import Foundation
import XCTest
@testable import CorePlayerEngine

@MainActor
final class MediaSessionCoordinatorTests: XCTestCase {
    private final class RecordingMediaSessionProvider: MediaSessionProviding {
        private(set) var snapshots: [NowPlayingSnapshot] = []
        private(set) var clearCount = 0

        private var playHandler: (() -> MediaSessionCommandResult)?
        private var pauseHandler: (() -> MediaSessionCommandResult)?
        private var toggleHandler: (() -> MediaSessionCommandResult)?
        private var seekHandler: ((TimeInterval) -> MediaSessionCommandResult)?

        func installCommandHandlers(
            onPlay: @escaping () -> MediaSessionCommandResult,
            onPause: @escaping () -> MediaSessionCommandResult,
            onTogglePlayback: @escaping () -> MediaSessionCommandResult,
            onSeek: @escaping (TimeInterval) -> MediaSessionCommandResult
        ) {
            playHandler = onPlay
            pauseHandler = onPause
            toggleHandler = onTogglePlayback
            seekHandler = onSeek
        }

        func publish(_ snapshot: NowPlayingSnapshot) {
            snapshots.append(snapshot)
        }

        func clear() {
            clearCount += 1
            snapshots.removeAll()
        }

        func sendPlay() -> MediaSessionCommandResult? { playHandler?() }
        func sendPause() -> MediaSessionCommandResult? { pauseHandler?() }
        func sendToggle() -> MediaSessionCommandResult? { toggleHandler?() }
        func sendSeek(_ seconds: TimeInterval) -> MediaSessionCommandResult? {
            seekHandler?(seconds)
        }
    }

    func testActivationPublishesMetadataAndObservedPlaybackSnapshot() {
        let provider = RecordingMediaSessionProvider()
        let coordinator = MediaSessionCoordinator(provider: provider)

        coordinator.activate(
            title: "Two-bedroom apartment",
            artist: "Estatia",
            state: .playing,
            currentTime: 18.5,
            duration: 92
        )

        XCTAssertEqual(
            provider.snapshots.last,
            NowPlayingSnapshot(
                title: "Two-bedroom apartment",
                artist: "Estatia",
                elapsedTime: 18.5,
                duration: 92,
                playbackRate: 1
            )
        )
    }

    func testPlaybackAndProgressUpdatesKeepMetadataAndSynchronizePosition() {
        let provider = RecordingMediaSessionProvider()
        let coordinator = MediaSessionCoordinator(provider: provider)
        coordinator.activate(
            title: "Listing video",
            artist: nil,
            state: .playing,
            currentTime: 4,
            duration: 30
        )

        coordinator.updateProgress(currentTime: 9.25, duration: 30)
        XCTAssertEqual(
            provider.snapshots.last,
            NowPlayingSnapshot(
                title: "Listing video",
                artist: nil,
                elapsedTime: 9.25,
                duration: 30,
                playbackRate: 1
            )
        )

        coordinator.updatePlayback(
            state: .buffering,
            currentTime: 9.25,
            duration: 30
        )
        XCTAssertEqual(provider.snapshots.last?.playbackRate, 0)
        XCTAssertEqual(provider.snapshots.last?.elapsedTime, 9.25)
        XCTAssertEqual(provider.snapshots.last?.title, "Listing video")
    }

    func testInvalidPositionAndDurationValuesAreSanitized() {
        let provider = RecordingMediaSessionProvider()
        let coordinator = MediaSessionCoordinator(provider: provider)

        coordinator.activate(
            title: nil,
            artist: nil,
            state: .paused,
            currentTime: .nan,
            duration: .infinity
        )

        XCTAssertEqual(
            provider.snapshots.last,
            NowPlayingSnapshot(
                title: nil,
                artist: nil,
                elapsedTime: 0,
                duration: nil,
                playbackRate: 0
            )
        )

        coordinator.updateProgress(currentTime: -10, duration: -1)
        XCTAssertEqual(provider.snapshots.last?.elapsedTime, 0)
        XCTAssertNil(provider.snapshots.last?.duration)
    }

    func testRemoteCommandHandlersAreForwardedAndClearRemovesSnapshot() {
        let provider = RecordingMediaSessionProvider()
        let coordinator = MediaSessionCoordinator(provider: provider)
        var seekPosition: TimeInterval?

        coordinator.installCommands(
            onPlay: { .success },
            onPause: { .success },
            onTogglePlayback: { .unavailable },
            onSeek: { seconds in
                seekPosition = seconds
                return .success
            }
        )
        coordinator.activate(
            title: "Remote controls",
            artist: "Estatia",
            state: .paused,
            currentTime: 0,
            duration: 12
        )

        XCTAssertEqual(provider.sendPlay(), .success)
        XCTAssertEqual(provider.sendPause(), .success)
        XCTAssertEqual(provider.sendToggle(), .unavailable)
        XCTAssertEqual(provider.sendSeek(7.5), .success)
        XCTAssertEqual(seekPosition, 7.5)

        coordinator.clear()
        XCTAssertEqual(provider.clearCount, 1)
        XCTAssertTrue(provider.snapshots.isEmpty)
    }
}
