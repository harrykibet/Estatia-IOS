import Foundation

public struct CdnHealth: Sendable, Equatable {
    public let latency: TimeInterval?
    public let consecutiveFailures: Int
    public let lastCheckedAt: Date
    public let circuitOpenUntil: Date?

    public init(latency: TimeInterval?, consecutiveFailures: Int, lastCheckedAt: Date, circuitOpenUntil: Date?) {
        self.latency = latency
        self.consecutiveFailures = consecutiveFailures
        self.lastCheckedAt = lastCheckedAt
        self.circuitOpenUntil = circuitOpenUntil
    }

    public func isCircuitOpen(at date: Date) -> Bool {
        guard let circuitOpenUntil else { return false }
        return date < circuitOpenUntil
    }
}

/// Thread-safe endpoint health state with asynchronous probes and a bounded circuit breaker.
public actor CdnHealthMonitor {
    private let measurer: any LatencyMeasurer
    private let clock: @Sendable () -> Date
    private let healthTTL: TimeInterval
    private let failureThreshold: Int
    private let circuitOpenDuration: TimeInterval

    private var healthByCDN: [String: CdnHealth] = [:]
    private var probeTasks: [String: Task<Void, Never>] = [:]
    private var probeTokens: [String: UUID] = [:]
    private var generations: [String: UInt64] = [:]

    public init(
        measurer: any LatencyMeasurer = DefaultLatencyMeasurer(),
        clock: @escaping @Sendable () -> Date = { Date() },
        healthTTL: TimeInterval = 30,
        failureThreshold: Int = 3,
        circuitOpenDuration: TimeInterval = 60
    ) {
        precondition(healthTTL > 0 && failureThreshold > 0 && circuitOpenDuration > 0)
        self.measurer = measurer
        self.clock = clock
        self.healthTTL = healthTTL
        self.failureThreshold = failureThreshold
        self.circuitOpenDuration = circuitOpenDuration
    }

    public func currentTime() -> Date { clock() }
    public func snapshot() -> [String: CdnHealth] { healthByCDN }
    public func health(for cdn: Cdn) -> CdnHealth? { healthByCDN[cdn.id] }

    public func recordFailure(for cdn: Cdn) {
        generations[cdn.id, default: 0] &+= 1
        let now = clock()
        let previous = healthByCDN[cdn.id]
        let failures = (previous?.consecutiveFailures ?? 0) + 1
        let openUntil = failures >= failureThreshold
            ? now.addingTimeInterval(circuitOpenDuration)
            : previous?.circuitOpenUntil
        healthByCDN[cdn.id] = CdnHealth(
            latency: previous?.latency,
            consecutiveFailures: failures,
            lastCheckedAt: now,
            circuitOpenUntil: openUntil
        )
    }

    public func recordSuccess(for cdn: Cdn, latency: TimeInterval? = nil) {
        generations[cdn.id, default: 0] &+= 1
        let validLatency = latency.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        healthByCDN[cdn.id] = CdnHealth(
            latency: validLatency ?? healthByCDN[cdn.id]?.latency,
            consecutiveFailures: 0,
            lastCheckedAt: clock(),
            circuitOpenUntil: nil
        )
    }

    /// Starts background probes for missing or stale endpoints without blocking playback.
    public func refreshIfStale(cdns: [Cdn]) {
        let now = clock()
        for cdn in cdns {
            guard probeTasks[cdn.id] == nil else { continue }
            let previous = healthByCDN[cdn.id]
            if let previous, now.timeIntervalSince(previous.lastCheckedAt) < healthTTL { continue }
            if previous?.isCircuitOpen(at: now) == true { continue }

            let probeURL: URL
            if let path = cdn.healthCheckPath,
               let resolved = URL(string: path, relativeTo: cdn.baseURL)?.absoluteURL {
                probeURL = resolved
            } else {
                probeURL = cdn.baseURL
            }

            let token = UUID()
            let generation = generations[cdn.id, default: 0]
            let measurer = self.measurer
            let clock = self.clock
            let cdnID = cdn.id
            probeTokens[cdn.id] = token

            probeTasks[cdn.id] = Task.detached { [weak self, measurer, clock] in
                let latency = await measurer.measure(url: probeURL)
                await self?.finishProbe(
                    cdnID: cdnID,
                    token: token,
                    generation: generation,
                    latency: latency,
                    checkedAt: clock()
                )
            }
        }
    }

    private func finishProbe(
        cdnID: String,
        token: UUID,
        generation: UInt64,
        latency: TimeInterval?,
        checkedAt: Date
    ) {
        guard probeTokens[cdnID] == token else { return }
        probeTokens[cdnID] = nil
        probeTasks[cdnID] = nil
        // A newer playback result must win over an older in-flight probe.
        guard generations[cdnID, default: 0] == generation else { return }

        if let latency, latency.isFinite, latency >= 0 {
            healthByCDN[cdnID] = CdnHealth(
                latency: latency,
                consecutiveFailures: 0,
                lastCheckedAt: checkedAt,
                circuitOpenUntil: nil
            )
        } else {
            let failures = (healthByCDN[cdnID]?.consecutiveFailures ?? 0) + 1
            let openUntil = failures >= failureThreshold
                ? checkedAt.addingTimeInterval(circuitOpenDuration)
                : nil
            healthByCDN[cdnID] = CdnHealth(
                latency: nil,
                consecutiveFailures: failures,
                lastCheckedAt: checkedAt,
                circuitOpenUntil: openUntil
            )
        }
    }
}
