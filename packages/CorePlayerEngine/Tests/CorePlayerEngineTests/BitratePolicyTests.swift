import XCTest
@testable import CorePlayerEngine

final class BitratePolicyTests: XCTestCase {
    private let policy = BitratePolicy()

    func testNetworkThroughputLeavesHeadroom() {
        let result = policy.calculateMaximumBitrate(
            for: BitratePolicyInput(
                estimatedThroughputBps: 8_000_000,
                bufferAheadSeconds: 10
            )
        )
        XCTAssertEqual(result, 6_000_000, accuracy: 1)
    }

    func testLowAndPrecautionaryBufferReduceBitrate() {
        let low = policy.calculateMaximumBitrate(
            for: BitratePolicyInput(
                estimatedThroughputBps: 8_000_000,
                bufferAheadSeconds: 1.5
            )
        )
        let precautionary = policy.calculateMaximumBitrate(
            for: BitratePolicyInput(
                estimatedThroughputBps: 8_000_000,
                bufferAheadSeconds: 4
            )
        )

        XCTAssertEqual(low, 3_000_000, accuracy: 1)
        XCTAssertEqual(precautionary, 4_800_000, accuracy: 1)
        XCTAssertLessThan(low, precautionary)
    }

    func testThermalPowerAndMeteringPenaltiesCompose() {
        let result = policy.calculateMaximumBitrate(
            for: BitratePolicyInput(
                estimatedThroughputBps: 8_000_000,
                bufferAheadSeconds: 10,
                thermalState: .serious,
                isLowPowerModeEnabled: true,
                isMetered: true
            )
        )

        XCTAssertEqual(result, 1_417_500, accuracy: 1)
    }

    func testConstrainedNetworkUsesStrongerPenaltyThanMetered() {
        let metered = policy.calculateMaximumBitrate(
            for: BitratePolicyInput(
                estimatedThroughputBps: 8_000_000,
                bufferAheadSeconds: 10,
                isMetered: true
            )
        )
        let constrained = policy.calculateMaximumBitrate(
            for: BitratePolicyInput(
                estimatedThroughputBps: 8_000_000,
                bufferAheadSeconds: 10,
                isMetered: true,
                isConstrained: true
            )
        )

        XCTAssertEqual(metered, 4_200_000, accuracy: 1)
        XCTAssertEqual(constrained, 3_300_000, accuracy: 1)
    }

    func testLiveAndStartupPlaybackUseConservativeCeilings() {
        let live = policy.calculateMaximumBitrate(
            for: BitratePolicyInput(
                estimatedThroughputBps: 8_000_000,
                bufferAheadSeconds: 10,
                contentType: .live
            )
        )
        let startup = policy.calculateMaximumBitrate(
            for: BitratePolicyInput(
                estimatedThroughputBps: 8_000_000,
                bufferAheadSeconds: 10,
                isStartup: true
            )
        )

        XCTAssertEqual(live, 4_500_000, accuracy: 1)
        XCTAssertEqual(startup, 3_300_000, accuracy: 1)
    }

    func testDeviceMaximumCapsNetworkDerivedTarget() {
        let result = policy.calculateMaximumBitrate(
            for: BitratePolicyInput(
                estimatedThroughputBps: 20_000_000,
                bufferAheadSeconds: 10,
                deviceMaximumBitrateBps: 2_000_000
            )
        )
        XCTAssertEqual(result, 2_000_000, accuracy: 1)
    }

    func testSlowNetworkIsNeverOverriddenByMinimumQualityFloor() {
        let result = policy.calculateMaximumBitrate(
            for: BitratePolicyInput(
                estimatedThroughputBps: 100_000,
                bufferAheadSeconds: 10
            )
        )
        XCTAssertEqual(result, 75_000, accuracy: 1)
        XCTAssertLessThanOrEqual(result, 100_000)
    }

    func testMissingOrInvalidThroughputUsesConservativeDefault() {
        let missing = policy.calculateMaximumBitrate(
            for: BitratePolicyInput(
                estimatedThroughputBps: nil,
                bufferAheadSeconds: 10
            )
        )
        let invalid = policy.calculateMaximumBitrate(
            for: BitratePolicyInput(
                estimatedThroughputBps: .nan,
                bufferAheadSeconds: 10
            )
        )

        XCTAssertEqual(missing, 1_125_000, accuracy: 1)
        XCTAssertEqual(invalid, missing, accuracy: 1)
    }
}

@MainActor
final class DynamicBitrateControllerTests: XCTestCase {
    private final class FakeBitrateTarget: AVPlayerProviding {
        var presentationPlayer: AVPlayer? { nil }
        var observedBitrateBps: Double? = nil
        private(set) var applied: [Double] = []

        func setPreferredPeakBitRate(_ bitrateBps: Double) {
            applied.append(bitrateBps)
        }
    }

    func testControllerAppliesAndSuppressesSmallChanges() {
        let controller = DynamicBitrateController()
        let target = FakeBitrateTarget()

        let first = controller.apply(
            BitratePolicyInput(
                estimatedThroughputBps: 8_000_000,
                bufferAheadSeconds: 10
            ),
            to: target
        )
        let smallChange = controller.apply(
            BitratePolicyInput(
                estimatedThroughputBps: 8_100_000,
                bufferAheadSeconds: 10
            ),
            to: target
        )
        let materialChange = controller.apply(
            BitratePolicyInput(
                estimatedThroughputBps: 9_000_000,
                bufferAheadSeconds: 10
            ),
            to: target
        )

        XCTAssertEqual(first, 6_000_000, accuracy: 1)
        XCTAssertEqual(smallChange, first, accuracy: 1)
        XCTAssertEqual(materialChange, 6_750_000, accuracy: 1)
        XCTAssertEqual(target.applied.count, 2)
    }

    func testResetRemovesTheAppliedBitrateLimit() {
        let controller = DynamicBitrateController()
        let target = FakeBitrateTarget()

        controller.apply(
            BitratePolicyInput(
                estimatedThroughputBps: 8_000_000,
                bufferAheadSeconds: 10
            ),
            to: target
        )
        controller.reset(for: target)

        XCTAssertEqual(target.applied.last, 0)
    }
}
