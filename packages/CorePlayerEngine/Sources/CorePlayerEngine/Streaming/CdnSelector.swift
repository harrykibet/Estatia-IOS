import Foundation

public final class CdnSelector: Sendable {
    private let cdns: [Cdn]
    private let healthMonitor: CdnHealthMonitor

    public init(
        cdns: [Cdn],
        measurer: any LatencyMeasurer = DefaultLatencyMeasurer(),
        healthMonitor: CdnHealthMonitor? = nil
    ) {
        self.cdns = cdns
        self.healthMonitor = healthMonitor ?? CdnHealthMonitor(measurer: measurer)
    }

    /// Selects the lowest-latency endpoint that is not circuit-open.
    /// If no probe has completed, configured order provides a deterministic fallback.
    public func selectBestCdn(
        forPath path: String,
        excluding excludedIDs: Set<String> = []
    ) async -> Cdn? {
        let candidates = cdns.filter { !excludedIDs.contains($0.id) }
        guard !candidates.isEmpty else { return nil }

        await healthMonitor.refreshIfStale(cdns: cdns)
        let snapshot = await healthMonitor.snapshot()
        let now = await healthMonitor.currentTime()
        let available = candidates.filter {
            snapshot[$0.id]?.isCircuitOpen(at: now) != true
        }

        let scored = available.compactMap { cdn -> (Cdn, TimeInterval)? in
            guard let health = snapshot[cdn.id], let latency = health.latency else { return nil }
            return (cdn, latency + TimeInterval(health.consecutiveFailures) * 0.250)
        }
        if let best = scored.min(by: { $0.1 < $1.1 })?.0 { return best }

        // Preserve an availability fallback if every circuit is open; an excluded
        // endpoint is still never reused during the same one-shot retry.
        return available.first ?? candidates.first
    }

    public func recordFailure(for cdn: Cdn) async {
        await healthMonitor.recordFailure(for: cdn)
    }

    public func recordSuccess(for cdn: Cdn, latency: TimeInterval? = nil) async {
        await healthMonitor.recordSuccess(for: cdn, latency: latency)
    }

    public func healthSnapshot() async -> [String: CdnHealth] {
        await healthMonitor.snapshot()
    }
}
