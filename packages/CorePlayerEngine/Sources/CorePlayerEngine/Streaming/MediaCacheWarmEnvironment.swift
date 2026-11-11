//
//  MediaCacheWarmEnvironment.swift
//  CorePlayerEngine
//
//  Created by builder on 9/23/26.
//


//
//  MediaCacheSizingPolicy.swift
//  CorePlayerEngine
//

import Foundation

public struct MediaCacheWarmEnvironment:
    Sendable,
    Equatable {

    public let isMetered: Bool
    public let isConstrained: Bool
    public let isLowPowerMode: Bool
    public let estimatedThroughputBps: Int64?

    public init(
        isMetered: Bool = false,
        isConstrained: Bool = false,
        isLowPowerMode: Bool = false,
        estimatedThroughputBps: Int64? = nil
    ) {
        self.isMetered = isMetered
        self.isConstrained = isConstrained
        self.isLowPowerMode = isLowPowerMode
        self.estimatedThroughputBps =
            estimatedThroughputBps
    }
}

public struct MediaCacheSizingPolicy:
    Sendable,
    Equatable {

    public let visibleBytes: Int64
    public let nextBytes: Int64
    public let previousBytes: Int64
    public let speculativeBytes: Int64

    /// Size of each disk cache chunk.
    public let chunkBytes: Int

    /// Upper bound used when storage capacity cannot be determined.
    public let maximumCacheBytes: Int64

    /// Lower bound for a known storage capacity, matching Android's cache policy.
    public let minimumCacheBytes: Int64

    /// Fraction of currently available filesystem storage reserved as the cache budget.
    public let storageBudgetFraction: Double

    public init(
        visibleBytes: Int64 = 4 * 1024 * 1024,
        nextBytes: Int64 = 2 * 1024 * 1024,
        previousBytes: Int64 = 1 * 1024 * 1024,
        speculativeBytes: Int64 = 512 * 1024,
        chunkBytes: Int = 512 * 1024,
        maximumCacheBytes: Int64 =
            512 * 1024 * 1024,
        minimumCacheBytes: Int64 =
            128 * 1024 * 1024,
        storageBudgetFraction: Double = 0.10
    ) {
        precondition(
            visibleBytes > 0
        )

        precondition(
            nextBytes > 0
        )

        precondition(
            previousBytes > 0
        )

        precondition(
            speculativeBytes > 0
        )

        precondition(
            chunkBytes > 0
        )

        precondition(
            maximumCacheBytes >= chunkBytes
        )

        precondition(
            minimumCacheBytes >= 0
        )

        precondition(
            storageBudgetFraction.isFinite &&
            storageBudgetFraction >= 0 &&
            storageBudgetFraction <= 1
        )

        self.visibleBytes = visibleBytes
        self.nextBytes = nextBytes
        self.previousBytes = previousBytes
        self.speculativeBytes = speculativeBytes
        self.chunkBytes = chunkBytes
        self.maximumCacheBytes =
            maximumCacheBytes
        self.minimumCacheBytes = minimumCacheBytes
        self.storageBudgetFraction = storageBudgetFraction
    }

    /// Resolves the aggregate playback-cache ceiling from free filesystem space.
    ///
    /// This mirrors Android's adaptive policy: use the configured fallback when
    /// capacity cannot be read; otherwise reserve the configured fraction of
    /// free space and clamp it between the minimum and maximum cache sizes.
    public func cacheLimitBytes(
        availableStorageBytes: Int64?
    ) -> Int64 {
        guard let availableStorageBytes,
              availableStorageBytes >= 0
        else {
            return maximumCacheBytes
        }

        let scaledBudget =
            Double(availableStorageBytes) * storageBudgetFraction

        let storageBudget: Int64
        if scaledBudget >= Double(Int64.max) {
            storageBudget = Int64.max
        } else {
            storageBudget = Int64(scaledBudget)
        }

        // Keep custom test/consumer configurations valid even when their
        // maximum is lower than the default minimum.
        let lowerBound = min(minimumCacheBytes, maximumCacheBytes)

        return min(
            maximumCacheBytes,
            max(lowerBound, storageBudget)
        )
    }

    public func budget(
        for priority: WarmPriority,
        environment:
            MediaCacheWarmEnvironment
    ) -> Int64 {

        let base: Int64

        switch priority {

        case .visible:
            base = visibleBytes

        case .next:
            base = nextBytes

        case .previous:
            base = previousBytes

        case .speculative:
            base = speculativeBytes
        }

        var multiplier = 1.0

        if environment.isConstrained {
            multiplier *= 0.25
        } else if environment.isMetered {
            multiplier *= 0.5
        }

        if environment.isLowPowerMode {
            multiplier *= 0.5
        }

        if let throughput =
            environment.estimatedThroughputBps,
           throughput < 1_000_000 {

            multiplier *= 0.5
        }

        let calculated =
            Int64(
                Double(base) *
                multiplier
            )

        return max(
            Int64(chunkBytes),
            calculated
        )
    }
}