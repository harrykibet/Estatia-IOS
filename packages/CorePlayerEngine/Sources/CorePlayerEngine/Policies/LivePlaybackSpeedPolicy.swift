import Foundation

/// Applies bounded playback-rate corrections for live media.
///
/// Positive offset error means playback is further behind the recommended live
/// edge than desired, so the controller speeds up. Negative error slows down.
/// VOD playback does not use this policy.
public struct LivePlaybackSpeedPolicy: Sendable {
    public let minimumPlaybackRate: Float
    public let maximumPlaybackRate: Float
    public let proportionalControlFactor: Double
    public let maximumOffsetErrorForUnitSpeed: TimeInterval

    public init(
        minimumPlaybackRate: Float = 0.97,
        maximumPlaybackRate: Float = 1.03,
        proportionalControlFactor: Double = 0.1,
        maximumOffsetErrorForUnitSpeed: TimeInterval = 0.020
    ) {
        precondition(minimumPlaybackRate > 0 && minimumPlaybackRate <= 1)
        precondition(maximumPlaybackRate >= 1 && maximumPlaybackRate.isFinite)
        precondition(proportionalControlFactor > 0 && proportionalControlFactor.isFinite)
        precondition(maximumOffsetErrorForUnitSpeed >= 0 && maximumOffsetErrorForUnitSpeed.isFinite)

        self.minimumPlaybackRate = minimumPlaybackRate
        self.maximumPlaybackRate = maximumPlaybackRate
        self.proportionalControlFactor = proportionalControlFactor
        self.maximumOffsetErrorForUnitSpeed = maximumOffsetErrorForUnitSpeed
    }

    /// Returns nil when AVFoundation has not supplied a valid live-offset
    /// snapshot. The caller should then restore normal playback speed.
    public func playbackRate(for timing: LivePlaybackTiming?) -> Float? {
        guard let timing,
              timing.currentOffsetSeconds.isFinite,
              timing.currentOffsetSeconds >= 0,
              timing.recommendedOffsetSeconds.isFinite,
              timing.recommendedOffsetSeconds >= 0
        else {
            return nil
        }

        let offsetError = timing.currentOffsetSeconds - timing.recommendedOffsetSeconds
        guard abs(offsetError) > maximumOffsetErrorForUnitSpeed else {
            return 1.0
        }

        let proportionalRate = 1.0 + proportionalControlFactor * offsetError
        guard proportionalRate.isFinite else { return nil }

        return Float(
            min(
                max(proportionalRate, Double(minimumPlaybackRate)),
                Double(maximumPlaybackRate)
            )
        )
    }
}

/// Applies live speed corrections to the AVFoundation player without taking
/// ownership of play/pause state. Rate changes are throttled to avoid jitter.
@MainActor
public final class LivePlaybackSpeedController {
    private struct AppliedRate {
        let rate: Float
        let uptime: TimeInterval
    }

    private let policy: LivePlaybackSpeedPolicy
    private let minimumUpdateInterval: TimeInterval
    private var appliedRates: [ObjectIdentifier: AppliedRate] = [:]

    public init(
        policy: LivePlaybackSpeedPolicy = LivePlaybackSpeedPolicy(),
        minimumUpdateInterval: TimeInterval = 1.0
    ) {
        precondition(minimumUpdateInterval > 0 && minimumUpdateInterval.isFinite)
        self.policy = policy
        self.minimumUpdateInterval = minimumUpdateInterval
    }

    @discardableResult
    public func apply(
        _ timing: LivePlaybackTiming?,
        to engine: any AVPlayerProviding,
        at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Float? {
        let identifier = ObjectIdentifier(engine)
        guard uptime.isFinite,
              let targetRate = policy.playbackRate(for: timing)
        else {
            reset(for: engine)
            return nil
        }

        if let previous = appliedRates[identifier] {
            // AVPlayer can restore defaultRate (normally 1.0) independently
            // of this controller, for example after play() or reaching live
            // edge. Do not trust our cached target when the actual transport
            // rate no longer matches it.
            let actualRateMatchesTarget = engine.currentPlaybackRate.map {
                $0.isFinite && abs($0 - targetRate) < 0.001
            } ?? true

            if abs(targetRate - previous.rate) < 0.001,
               actualRateMatchesTarget {
                return previous.rate
            }

            if uptime >= previous.uptime,
               uptime - previous.uptime < minimumUpdateInterval {
                return previous.rate
            }
        }

        engine.setLivePlaybackSpeed(targetRate)
        appliedRates[identifier] = AppliedRate(rate: targetRate, uptime: uptime)
        return targetRate
    }

    /// Returns a player to normal speed and forgets its prior adjustment.
    public func reset(for engine: any AVPlayerProviding) {
        guard appliedRates.removeValue(forKey: ObjectIdentifier(engine)) != nil else {
            return
        }
        engine.setLivePlaybackSpeed(1.0)
    }
}
