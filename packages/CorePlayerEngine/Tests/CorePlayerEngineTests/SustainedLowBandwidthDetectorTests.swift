import XCTest
@testable import CorePlayerEngine

final class SustainedLowBandwidthDetectorTests: XCTestCase {
    func testWarningActivatesOnlyAfterThreeConsecutiveLowSamples() {
        var detector = SustainedLowBandwidthDetector()

        XCTAssertFalse(detector.record(throughputBps: 420_000))
        XCTAssertFalse(detector.isSustainedLowBandwidth)
        XCTAssertFalse(detector.record(throughputBps: 470_000))
        XCTAssertFalse(detector.isSustainedLowBandwidth)

        XCTAssertTrue(detector.record(throughputBps: 490_000))
        XCTAssertTrue(detector.isSustainedLowBandwidth)
    }

    func testDuplicateThroughputValuesDoNotCountAsNewSamples() {
        var detector = SustainedLowBandwidthDetector()

        XCTAssertFalse(detector.record(throughputBps: 400_000))
        XCTAssertFalse(detector.record(throughputBps: 400_000))
        XCTAssertEqual(detector.consecutiveLowSampleCount, 1)

        XCTAssertFalse(detector.record(throughputBps: 450_000))
        XCTAssertFalse(detector.record(throughputBps: 450_000))
        XCTAssertEqual(detector.consecutiveLowSampleCount, 2)

        XCTAssertTrue(detector.record(throughputBps: 490_000))
        XCTAssertTrue(detector.isSustainedLowBandwidth)
    }

    func testRecoveryThresholdUsesHysteresis() {
        var detector = SustainedLowBandwidthDetector()

        _ = detector.record(throughputBps: 400_000)
        _ = detector.record(throughputBps: 450_000)
        _ = detector.record(throughputBps: 480_000)
        XCTAssertTrue(detector.isSustainedLowBandwidth)

        // The midpoint band does not clear a warning.
        XCTAssertFalse(detector.record(throughputBps: 650_000))
        XCTAssertTrue(detector.isSustainedLowBandwidth)

        // Recovery is strict: exactly 800 kbps is still in the hysteresis band.
        XCTAssertFalse(detector.record(throughputBps: 800_000))
        XCTAssertTrue(detector.isSustainedLowBandwidth)

        XCTAssertTrue(detector.record(throughputBps: 800_001))
        XCTAssertFalse(detector.isSustainedLowBandwidth)
        XCTAssertEqual(detector.consecutiveLowSampleCount, 0)
    }

    func testIntermediateSamplePreservesConsecutiveLowCount() {
        var detector = SustainedLowBandwidthDetector()

        _ = detector.record(throughputBps: 300_000)
        _ = detector.record(throughputBps: 350_000)
        XCTAssertEqual(detector.consecutiveLowSampleCount, 2)

        _ = detector.record(throughputBps: 700_000)
        XCTAssertEqual(detector.consecutiveLowSampleCount, 2)

        XCTAssertTrue(detector.record(throughputBps: 450_000))
        XCTAssertTrue(detector.isSustainedLowBandwidth)
    }

    func testHighSampleResetsAnIncompleteLowBandwidthSequence() {
        var detector = SustainedLowBandwidthDetector()

        _ = detector.record(throughputBps: 300_000)
        _ = detector.record(throughputBps: 350_000)
        XCTAssertEqual(detector.consecutiveLowSampleCount, 2)

        _ = detector.record(throughputBps: 900_000)
        XCTAssertEqual(detector.consecutiveLowSampleCount, 0)
        XCTAssertFalse(detector.isSustainedLowBandwidth)

        _ = detector.record(throughputBps: 400_000)
        XCTAssertEqual(detector.consecutiveLowSampleCount, 1)
        XCTAssertFalse(detector.isSustainedLowBandwidth)
    }

    func testMissingOrInvalidSamplesDoNotChangeDetectorState() {
        var detector = SustainedLowBandwidthDetector()

        _ = detector.record(throughputBps: 300_000)
        XCTAssertFalse(detector.record(throughputBps: nil))
        XCTAssertFalse(detector.record(throughputBps: .nan))
        XCTAssertFalse(detector.record(throughputBps: .infinity))
        XCTAssertFalse(detector.record(throughputBps: -1))
        XCTAssertEqual(detector.consecutiveLowSampleCount, 1)
        XCTAssertFalse(detector.isSustainedLowBandwidth)
    }

    func testResetClearsCountAndActiveWarning() {
        var detector = SustainedLowBandwidthDetector()

        _ = detector.record(throughputBps: 300_000)
        _ = detector.record(throughputBps: 350_000)
        _ = detector.record(throughputBps: 400_000)
        XCTAssertTrue(detector.isSustainedLowBandwidth)

        XCTAssertTrue(detector.reset())
        XCTAssertFalse(detector.reset())
        XCTAssertFalse(detector.isSustainedLowBandwidth)
        XCTAssertEqual(detector.consecutiveLowSampleCount, 0)
    }
}
