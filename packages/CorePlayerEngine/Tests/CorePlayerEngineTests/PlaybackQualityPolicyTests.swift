import XCTest
@testable import CorePlayerEngine

final class PlaybackQualityPolicyTests: XCTestCase {
    private let policy = PlaybackQualityPolicy()

    func testHighMatchAllowsUpTo1080pWithoutAddingBitrateCap() {
        let preferences = policy.preferences(
            matchScore: 0.91,
            thermalState: .nominal
        )

        XCTAssertEqual(
            preferences.maximumResolution,
            VideoResolution(width: 1920, height: 1080)
        )
        XCTAssertNil(preferences.maximumPeakBitrateBps)
    }

    func testLowMatchCapsResolutionAt360p() {
        let preferences = policy.preferences(
            matchScore: 0.39,
            thermalState: .nominal
        )

        XCTAssertEqual(
            preferences.maximumResolution,
            VideoResolution(width: 640, height: 360)
        )
        XCTAssertNil(preferences.maximumPeakBitrateBps)
    }

    func testMiddleMatchScoreDoesNotAddResolutionCeiling() {
        let preferences = policy.preferences(
            matchScore: 0.65,
            thermalState: .nominal
        )

        XCTAssertNil(preferences.maximumResolution)
        XCTAssertNil(preferences.maximumPeakBitrateBps)
    }

    func testInvalidMatchScoreUsesNeutralDefault() {
        let preferences = policy.preferences(
            matchScore: .nan,
            thermalState: .nominal
        )

        XCTAssertEqual(preferences, .unrestricted)
    }

    func testNonNominalThermalStateAppliesTwoMegabitCeiling() {
        for thermalState in [
            PlayerPoolEnvironment.ThermalState.fair,
            .serious,
            .critical
        ] {
            let preferences = policy.preferences(
                matchScore: 0.65,
                thermalState: thermalState
            )

            XCTAssertNil(preferences.maximumResolution)
            XCTAssertEqual(preferences.maximumPeakBitrateBps, 2_000_000)
        }
    }

    func testMatchAndThermalConstraintsCompose() {
        let preferences = policy.preferences(
            matchScore: 0.95,
            thermalState: .serious
        )

        XCTAssertEqual(
            preferences.maximumResolution,
            VideoResolution(width: 1920, height: 1080)
        )
        XCTAssertEqual(preferences.maximumPeakBitrateBps, 2_000_000)
    }

    func testPreferencesRejectNonPositiveOrNonFiniteBitrateCaps() {
        XCTAssertNil(
            PlaybackQualityPreferences(maximumPeakBitrateBps: 0)
                .maximumPeakBitrateBps
        )
        XCTAssertNil(
            PlaybackQualityPreferences(maximumPeakBitrateBps: .infinity)
                .maximumPeakBitrateBps
        )
    }
}
