import XCTest
@testable import CorePlayerEngine

final class MediaCacheSizingPolicyTests: XCTestCase {
    private let mebibyte: Int64 = 1024 * 1024

    func testUnknownStorageUsesConfiguredDefaultCeiling() {
        let policy = MediaCacheSizingPolicy()

        XCTAssertEqual(
            policy.cacheLimitBytes(availableStorageBytes: nil),
            512 * mebibyte
        )
    }

    func testNegativeStorageMeasurementUsesConfiguredDefaultCeiling() {
        let policy = MediaCacheSizingPolicy()

        XCTAssertEqual(
            policy.cacheLimitBytes(availableStorageBytes: -1),
            512 * mebibyte
        )
    }

    func testTenPercentBudgetIsClampedToMinimum() {
        let policy = MediaCacheSizingPolicy()

        XCTAssertEqual(
            policy.cacheLimitBytes(
                availableStorageBytes: 512 * mebibyte
            ),
            128 * mebibyte
        )
    }

    func testKnownStorageUsesConfiguredFraction() {
        let policy = MediaCacheSizingPolicy()

        XCTAssertEqual(
            policy.cacheLimitBytes(
                availableStorageBytes: 2 * 1024 * mebibyte
            ),
            214_748_364
        )
    }

    func testStorageBudgetIsClampedToMaximum() {
        let policy = MediaCacheSizingPolicy()

        XCTAssertEqual(
            policy.cacheLimitBytes(
                availableStorageBytes: 10 * 1024 * mebibyte
            ),
            512 * mebibyte
        )
    }

    func testCustomMaximumRemainsValidWhenBelowMinimum() {
        let policy = MediaCacheSizingPolicy(
            visibleBytes: 1,
            nextBytes: 1,
            previousBytes: 1,
            speculativeBytes: 1,
            chunkBytes: 1,
            maximumCacheBytes: 1_000,
            minimumCacheBytes: 5_000,
            storageBudgetFraction: 0.10
        )

        XCTAssertEqual(
            policy.cacheLimitBytes(availableStorageBytes: 100_000),
            1_000
        )
    }

    func testVeryLargeStorageMeasurementDoesNotOverflow() {
        let policy = MediaCacheSizingPolicy(
            storageBudgetFraction: 1
        )

        XCTAssertEqual(
            policy.cacheLimitBytes(
                availableStorageBytes: Int64.max
            ),
            512 * mebibyte
        )
    }
}
