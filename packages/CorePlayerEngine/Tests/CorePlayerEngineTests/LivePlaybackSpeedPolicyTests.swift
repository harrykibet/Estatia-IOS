import AVFoundation
import XCTest
@testable import CorePlayerEngine

final class LivePlaybackSpeedPolicyTests: XCTestCase {
    private let policy = LivePlaybackSpeedPolicy()

    func testPlaybackFartherBehindThanRecommendedSpeedsUpWithinAndroidBounds() {
        let rate = policy.playbackRate(
            for: LivePlaybackTiming(
                currentOffsetSeconds: 10,
                recommendedOffsetSeconds: 5
            )
        )

        XCTAssertEqual(rate ?? .nan, 1.03, accuracy: 0.0001)
    }

    func testPlaybackCloserToLiveThanRecommendedSlowsDownWithinAndroidBounds() {
        let rate = policy.playbackRate(
            for: LivePlaybackTiming(
                currentOffsetSeconds: 2,
                recommendedOffsetSeconds: 5
            )
        )

        XCTAssertEqual(rate ?? .nan, 0.97, accuracy: 0.0001)
    }

    func testSmallOffsetErrorKeepsNormalSpeed() {
        let rate = policy.playbackRate(
            for: LivePlaybackTiming(
                currentOffsetSeconds: 5.01,
                recommendedOffsetSeconds: 5
            )
        )

        XCTAssertEqual(rate, 1.0)
    }

    func testProportionalCorrectionIsAppliedBeforeClamping() {
        let rate = policy.playbackRate(
            for: LivePlaybackTiming(
                currentOffsetSeconds: 5.1,
                recommendedOffsetSeconds: 5
            )
        )

        XCTAssertEqual(rate ?? .nan, 1.01, accuracy: 0.0001)
    }

    func testInvalidOrMissingLiveTimingDoesNotProduceARate() {
        XCTAssertNil(policy.playbackRate(for: nil))
        XCTAssertNil(
            policy.playbackRate(
                for: LivePlaybackTiming(
                    currentOffsetSeconds: .nan,
                    recommendedOffsetSeconds: 5
                )
            )
        )
        XCTAssertNil(
            policy.playbackRate(
                for: LivePlaybackTiming(
                    currentOffsetSeconds: 5,
                    recommendedOffsetSeconds: .infinity
                )
            )
        )
        XCTAssertNil(
            policy.playbackRate(
                for: LivePlaybackTiming(
                    currentOffsetSeconds: -1,
                    recommendedOffsetSeconds: 5
                )
            )
        )
    }
}

@MainActor
final class LivePlaybackSpeedControllerTests: XCTestCase {
    private final class FakePlayer: AVPlayerProviding {
        var presentationPlayer: AVPlayer?
        var observedBitrateBps: Double?
        var livePlaybackTiming: LivePlaybackTiming?
        var currentPlaybackRate: Float? = 1.0
        private(set) var livePlaybackEnabled = false
        private(set) var appliedRates: [Float] = []

        func setPreferredPeakBitRate(_ bitrateBps: Double) {}
        func setPlaybackQuality(_ preferences: PlaybackQualityPreferences) {}
        func setLivePlaybackEnabled(_ enabled: Bool) {
            livePlaybackEnabled = enabled
        }
        func setLivePlaybackSpeed(_ speed: Float) {
            appliedRates.append(speed)
            currentPlaybackRate = speed
        }
    }

    func testControllerThrottlesCorrectionsToOnePerSecond() {
        let controller = LivePlaybackSpeedController()
        let player = FakePlayer()

        let first = controller.apply(
            LivePlaybackTiming(currentOffsetSeconds: 10, recommendedOffsetSeconds: 5),
            to: player,
            at: 10
        )
        let throttled = controller.apply(
            LivePlaybackTiming(currentOffsetSeconds: 0, recommendedOffsetSeconds: 5),
            to: player,
            at: 10.5
        )
        let next = controller.apply(
            LivePlaybackTiming(currentOffsetSeconds: 0, recommendedOffsetSeconds: 5),
            to: player,
            at: 11
        )

        XCTAssertEqual(first ?? .nan, 1.03, accuracy: 0.0001)
        XCTAssertEqual(throttled ?? .nan, 1.03, accuracy: 0.0001)
        XCTAssertEqual(next ?? .nan, 0.97, accuracy: 0.0001)
        XCTAssertEqual(player.appliedRates, [1.03, 0.97])
    }

    func testControllerReappliesCorrectionAfterPlayerRateResetsToDefault() {
        let controller = LivePlaybackSpeedController()
        let player = FakePlayer()
        let timing = LivePlaybackTiming(
            currentOffsetSeconds: 10,
            recommendedOffsetSeconds: 5
        )

        _ = controller.apply(timing, to: player, at: 10)
        XCTAssertEqual(player.currentPlaybackRate ?? .nan, 1.03, accuracy: 0.0001)

        // Simulate AVPlayer.play() or a live-edge transition restoring
        // defaultRate while the controller still has 1.03 cached.
        player.currentPlaybackRate = 1.0

        let throttled = controller.apply(timing, to: player, at: 10.5)
        XCTAssertEqual(throttled ?? .nan, 1.03, accuracy: 0.0001)
        XCTAssertEqual(player.appliedRates, [1.03])

        let resynchronized = controller.apply(timing, to: player, at: 11)
        XCTAssertEqual(resynchronized ?? .nan, 1.03, accuracy: 0.0001)
        XCTAssertEqual(player.currentPlaybackRate ?? .nan, 1.03, accuracy: 0.0001)
        XCTAssertEqual(player.appliedRates, [1.03, 1.03])
    }

    func testMissingTimingRestoresNormalSpeedAfterAnAdjustment() {
        let controller = LivePlaybackSpeedController()
        let player = FakePlayer()

        _ = controller.apply(
            LivePlaybackTiming(currentOffsetSeconds: 10, recommendedOffsetSeconds: 5),
            to: player,
            at: 10
        )
        let result = controller.apply(nil, to: player, at: 11)

        XCTAssertNil(result)
        XCTAssertEqual(player.appliedRates, [1.03, 1.0])
    }

    func testResetRestoresNormalSpeedAndForgetsPriorRate() {
        let controller = LivePlaybackSpeedController()
        let player = FakePlayer()

        _ = controller.apply(
            LivePlaybackTiming(currentOffsetSeconds: 10, recommendedOffsetSeconds: 5),
            to: player,
            at: 10
        )
        controller.reset(for: player)
        _ = controller.apply(
            LivePlaybackTiming(currentOffsetSeconds: 0, recommendedOffsetSeconds: 5),
            to: player,
            at: 10.1
        )

        XCTAssertEqual(player.appliedRates, [1.03, 1.0, 0.97])
    }
}
