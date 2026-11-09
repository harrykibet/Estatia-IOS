import Foundation

/// Mirrors the Android player's sustained-bandwidth warning thresholds.
///
/// Three low-throughput samples are required before warning. Once active,
/// the warning remains active through the hysteresis band and clears only
/// when throughput rises above the recovery threshold.
struct SustainedLowBandwidthDetector: Sendable {
    static let lowBandwidthThresholdBps = 500_000.0
    static let recoveryThresholdBps = 800_000.0
    static let consecutiveSampleThreshold = 3

    private(set) var consecutiveLowSampleCount = 0
    private(set) var isSustainedLowBandwidth = false
    private var previousThroughputBps: Double?

    /// Records one measured throughput sample.
    ///
    /// - Returns: Whether the public warning state changed.
    @discardableResult
    mutating func record(throughputBps: Double?) -> Bool {
        guard let throughputBps,
              throughputBps.isFinite,
              throughputBps >= 0
        else {
            return false
        }

        // Android's BandwidthMeter flow applies distinctUntilChanged before
        // incrementing its consecutive-sample counter. Mirror that here so
        // repeated progress ticks do not count the same access-log estimate.
        guard previousThroughputBps != throughputBps else {
            return false
        }
        previousThroughputBps = throughputBps

        let previousState = isSustainedLowBandwidth

        if throughputBps < Self.lowBandwidthThresholdBps {
            consecutiveLowSampleCount = min(
                consecutiveLowSampleCount + 1,
                Self.consecutiveSampleThreshold
            )
        } else if throughputBps > Self.recoveryThresholdBps {
            consecutiveLowSampleCount = 0
            isSustainedLowBandwidth = false
        }

        if consecutiveLowSampleCount >= Self.consecutiveSampleThreshold {
            isSustainedLowBandwidth = true
        }

        return previousState != isSustainedLowBandwidth
    }

    /// Resets the detector when playback ownership changes.
    @discardableResult
    mutating func reset() -> Bool {
        let previousState = isSustainedLowBandwidth
        consecutiveLowSampleCount = 0
        isSustainedLowBandwidth = false
        previousThroughputBps = nil
        return previousState
    }
}
