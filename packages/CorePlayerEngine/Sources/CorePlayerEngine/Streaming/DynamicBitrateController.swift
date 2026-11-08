import Foundation

/// Applies bitrate ceilings to an AVFoundation-backed engine. The controller
/// is main-actor isolated because AVPlayerProviding is a main-actor contract.
@MainActor
public final class DynamicBitrateController {
    private let policy: BitratePolicy
    private var lastAppliedByEngine: [ObjectIdentifier: Double] = [:]

    public init(policy: BitratePolicy = BitratePolicy()) {
        self.policy = policy
    }

    /// Calculates and applies the maximum rendition bitrate.
    /// Repeated near-identical targets are ignored to avoid needlessly
    /// mutating AVPlayerItem on every progress tick.
    @discardableResult
    public func apply(
        _ input: BitratePolicyInput,
        to engine: any AVPlayerProviding
    ) -> Double {
        let target = policy.calculateMaximumBitrate(for: input)
        let identifier = ObjectIdentifier(engine)

        if let previous = lastAppliedByEngine[identifier] {
            let difference = abs(target - previous)
            let threshold = max(50_000, previous * 0.05)
            guard difference >= threshold else {
                return previous
            }
        }

        engine.setPreferredPeakBitRate(target)
        lastAppliedByEngine[identifier] = target
        return target
    }

    public func reset(for engine: any AVPlayerProviding) {
        let identifier = ObjectIdentifier(engine)
        lastAppliedByEngine.removeValue(forKey: identifier)
        engine.setPreferredPeakBitRate(0)
    }

    public func resetAll() {
        lastAppliedByEngine.removeAll()
    }
}
