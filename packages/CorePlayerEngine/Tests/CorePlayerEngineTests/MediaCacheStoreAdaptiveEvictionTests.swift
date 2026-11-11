import XCTest
@testable import CorePlayerEngine

@available(iOS 18.0, macOS 10.15, *)
final class MediaCacheStoreAdaptiveEvictionTests: XCTestCase {
    func testEveryWriteEnforcesStorageAwareLRUCeiling() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let policy = MediaCacheSizingPolicy(
            visibleBytes: 1,
            nextBytes: 1,
            previousBytes: 1,
            speculativeBytes: 1,
            chunkBytes: 1,
            maximumCacheBytes: 100,
            minimumCacheBytes: 50,
            storageBudgetFraction: 0.50
        )
        let store = FileMediaCacheStore(
            rootDirectory: directory,
            sizingPolicy: policy,
            availableStorageBytesProvider: { 100 }
        )

        try await store.writeChunk(
            key: "older-media",
            offset: 0,
            data: Data(repeating: 1, count: 30)
        )

        // Ensure the two entries have a stable LRU ordering even on filesystems
        // whose metadata timestamps have coarse resolution.
        try await Task.sleep(for: .milliseconds(20))

        try await store.writeChunk(
            key: "current-media",
            offset: 0,
            data: Data(repeating: 2, count: 30)
        )

        let statistics = try await store.statistics()
        let olderEntry = try await store.entry(key: "older-media")
        let currentEntry = try await store.entry(key: "current-media")

        XCTAssertEqual(statistics.totalBytes, 30)
        XCTAssertNil(olderEntry)
        XCTAssertEqual(currentEntry?.cachedByteCount, 30)
    }

    func testUnavailableStorageFallsBackToDefaultCeiling() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let policy = MediaCacheSizingPolicy(
            visibleBytes: 1,
            nextBytes: 1,
            previousBytes: 1,
            speculativeBytes: 1,
            chunkBytes: 1,
            maximumCacheBytes: 100,
            minimumCacheBytes: 50,
            storageBudgetFraction: 0.50
        )
        let store = FileMediaCacheStore(
            rootDirectory: directory,
            sizingPolicy: policy,
            availableStorageBytesProvider: { nil }
        )

        try await store.writeChunk(
            key: "media-one",
            offset: 0,
            data: Data(repeating: 1, count: 40)
        )
        try await store.writeChunk(
            key: "media-two",
            offset: 0,
            data: Data(repeating: 2, count: 40)
        )

        let statistics = try await store.statistics()
        XCTAssertEqual(statistics.totalBytes, 80)
        XCTAssertEqual(statistics.entryCount, 2)
    }
}
