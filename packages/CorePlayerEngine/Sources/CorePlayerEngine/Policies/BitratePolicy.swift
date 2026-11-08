import Foundation

/// Distinguishes live delivery from on-demand playback. This is intentionally
/// separate from MediaType, which describes the container/transport format.
public enum PlaybackContentType: Sendable, Equatable {
    case live
    case onDemand
}

/// Runtime inputs used to calculate a safe AVPlayer peak-bitrate ceiling.
public struct BitratePolicyInput: Sendable, Equatable {
    public let estimatedThroughputBps: Double?
    public let bufferAheadSeconds: TimeInterval?
    public let thermalState: PlayerPoolEnvironment.ThermalState
    public let isLowPowerModeEnabled: Bool
    public let isMetered: Bool
    public let isConstrained: Bool
    public let contentType: PlaybackContentType
    public let isStartup: Bool
    public let deviceMaximumBitrateBps: Double?

    public init(
        estimatedThroughputBps: Double?,
        bufferAheadSeconds: TimeInterval?,
        thermalState: PlayerPoolEnvironment.ThermalState = .nominal,
        isLowPowerModeEnabled: Bool = false,
        isMetered: Bool = false,
        isConstrained: Bool = false,
        contentType: PlaybackContentType = .onDemand,
        isStartup: Bool = false,
        deviceMaximumBitrateBps: Double? = nil
    ) {
        self.estimatedThroughputBps = estimatedThroughputBps
        self.bufferAheadSeconds = bufferAheadSeconds
        self.thermalState = thermalState
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.isMetered = isMetered
        self.isConstrained = isConstrained
        self.contentType = contentType
        self.isStartup = isStartup
        self.deviceMaximumBitrateBps = deviceMaximumBitrateBps
    }
}

/// BOLA-lite bitrate policy. The result is a peak ceiling in bits per second,
/// not a promise that the selected rendition will have exactly this bitrate.
public struct BitratePolicy: Sendable {
    public let defaultThroughputBps: Double
    public let maximumBitrateBps: Double
    public let minimumBitrateBps: Double

    public init(
        defaultThroughputBps: Double = 1_500_000,
        minimumBitrateBps: Double = 128_000,
        maximumBitrateBps: Double = 12_000_000
    ) {
        precondition(defaultThroughputBps > 0)
        precondition(minimumBitrateBps > 0)
        precondition(maximumBitrateBps >= minimumBitrateBps)
        self.defaultThroughputBps = defaultThroughputBps
        self.minimumBitrateBps = minimumBitrateBps
        self.maximumBitrateBps = maximumBitrateBps
    }

    public func calculateMaximumBitrate(for input: BitratePolicyInput) -> Double {
        let measuredThroughput = input.estimatedThroughputBps.flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        } ?? defaultThroughputBps

        // Keep headroom for protocol overhead, retransmissions, and short-term
        // throughput variation rather than targeting the full measured rate.
        let networkCeiling = min(maximumBitrateBps, measuredThroughput * 0.75)
        var target = networkCeiling

        if input.isConstrained {
            target *= 0.55
        } else if input.isMetered {
            target *= 0.70
        }

        if input.isLowPowerModeEnabled {
            target *= 0.75
        }

        switch input.thermalState {
        case .nominal:
            break
        case .fair:
            target *= 0.75
        case .serious:
            target *= 0.45
        case .critical:
            target *= 0.20
        }

        // Buffer ahead is loaded-end-time minus current time. Unknown buffer
        // is treated conservatively during startup/recovery.
        let buffer = input.bufferAheadSeconds.flatMap {
            $0.isFinite && $0 >= 0 ? $0 : nil
        } ?? 0

        if buffer < 2 {
            target *= 0.50
        } else if buffer < 5 {
            target *= 0.80
        }

        if input.contentType == .live {
            target *= 0.75
        }

        if input.isStartup {
            target *= 0.55
        }

        if let deviceMaximum = input.deviceMaximumBitrateBps,
           deviceMaximum.isFinite,
           deviceMaximum > 0 {
            target = min(target, deviceMaximum)
        }

        // Do not let a minimum-quality floor exceed a genuinely slow measured
        // network. The floor is bounded by the measured network ceiling.
        let floor = min(minimumBitrateBps, networkCeiling)
        return min(networkCeiling, max(floor, target))
    }
}
