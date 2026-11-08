import XCTest
@testable import CorePlayerEngine

@MainActor
final class PlayerPoolTests: XCTestCase {

    // MARK: - Fake Engine

    final class FakePlayerEngine: PlayerEngine {

        private let stateStream: AsyncStream<PlayerState>
        private let eventStream: AsyncStream<PlayerEvent>

        private var stateContinuation: AsyncStream<PlayerState>.Continuation?
        private var eventContinuation: AsyncStream<PlayerEvent>.Continuation?

        private(set) var loadCount = 0
        private(set) var loadedMediaIds: [String] = []
        private(set) var playCount = 0
        private(set) var pauseCount = 0
        private(set) var stopCount = 0
        private(set) var releaseCount = 0

        init() {

            var stateContinuation: AsyncStream<PlayerState>.Continuation?
            var eventContinuation: AsyncStream<PlayerEvent>.Continuation?

            self.stateStream = AsyncStream { continuation in
                stateContinuation = continuation
            }

            self.eventStream = AsyncStream { continuation in
                eventContinuation = continuation
            }

            self.stateContinuation = stateContinuation
            self.eventContinuation = eventContinuation
        }

        var state: AsyncStream<PlayerState> {
            stateStream
        }

        var events: AsyncStream<PlayerEvent> {
            eventStream
        }

        func load(_ source: MediaSource) async throws {
            loadCount += 1

            // Force a suspension point so concurrent pool callers
            // can exercise pool serialization.
            await Task.yield()

            stateContinuation?.yield(.ready)
        }

        func load(
            mediaId: String,
            source: MediaSource
        ) async throws {
            loadedMediaIds.append(mediaId)
            try await load(source)
        }

        func play() async throws {
            playCount += 1
            stateContinuation?.yield(.playing)
        }

        func pause() async throws {
            pauseCount += 1
            stateContinuation?.yield(.paused)
        }

        func seek(to seconds: TimeInterval) async throws {}

        func stop() async throws {
            stopCount += 1
            stateContinuation?.yield(.idle)
        }

        func release() async throws {
            releaseCount += 1
            stateContinuation?.finish()
            eventContinuation?.finish()
        }

        var currentState: PlayerState {
            get async {
                .idle
            }
        }

        func notifyNetworkLost() async {}

        func notifyRecoveryExhausted() async {}

        var currentTime: TimeInterval {
            get async {
                0
            }
        }

        var duration: TimeInterval? {
            get async {
                nil
            }
        }
    }

    private func makeSource(
        _ id: String
    ) -> MediaSource {
        MediaSource(
            url: URL(
                string: "https://example.com/\(id).mp4"
            )!,
            type: .auto
        )
    }

    // MARK: - Tests

    func testPrewarmCreatesPlayer() async {

        var created: [FakePlayerEngine] = []

        let pool = PlayerPool(
            configuration: PlayerPoolConfiguration(
                maxPlayers: 3,
                maxIdlePlayers: 2
            ),
            factory: {
                let engine = FakePlayerEngine()
                created.append(engine)
                return engine
            }
        )

        let success = await pool.prewarm(
            mediaId: "one",
            source: makeSource("one")
        )

        XCTAssertTrue(success)
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(
            created[0].loadedMediaIds,
            ["one"]
        )
        let activeCount = pool.activeCount
        let idleCount = pool.idleCount

        XCTAssertEqual(activeCount, 1)
        XCTAssertEqual(idleCount, 0)
    }

    func testReleasedPlayerIsReused() async {

        var created: [FakePlayerEngine] = []

        let pool = PlayerPool(
            configuration: PlayerPoolConfiguration(
                maxPlayers: 2,
                maxIdlePlayers: 1
            ),
            factory: {
                let engine = FakePlayerEngine()
                created.append(engine)
                return engine
            }
        )

        let first = try! await pool.getOrCreate(
            mediaId: "one",
            source: makeSource("one")
        )

        await pool.release(mediaId: "one")

        let second = try! await pool.getOrCreate(
            mediaId: "two",
            source: makeSource("two")
        )

        XCTAssertEqual(created.count, 1)
        XCTAssertTrue(first.engine === second.engine)
        XCTAssertEqual(second.mediaId, "two")
    }

    func testLeastRecentlyUsedUnpinnedPlayerIsRecycled() async {

        var created: [FakePlayerEngine] = []

        let pool = PlayerPool(
            configuration: PlayerPoolConfiguration(
                maxPlayers: 2,
                maxIdlePlayers: 0
            ),
            factory: {
                let engine = FakePlayerEngine()
                created.append(engine)
                return engine
            }
        )

        let first = try! await pool.getOrCreate(
            mediaId: "one",
            source: makeSource("one")
        )

        let second = try! await pool.getOrCreate(
            mediaId: "two",
            source: makeSource("two")
        )

        await pool.updatePinnedIds(["one"])

        _ = try! await pool.getOrCreate(
            mediaId: "three",
            source: makeSource("three")
        )

        XCTAssertEqual(created.count, 2)

        let recycledPlayer = await pool.get(mediaId: "three")
        let pinnedPlayer = await pool.get(mediaId: "one")

        XCTAssertTrue(second.engine === recycledPlayer?.engine)
        XCTAssertTrue(first.engine === pinnedPlayer?.engine)
    }

    func testPinnedPlayersCannotBeEvicted() async {

        let pool = PlayerPool(
            configuration: PlayerPoolConfiguration(
                maxPlayers: 2,
                maxIdlePlayers: 0
            ),
            factory: {
                FakePlayerEngine()
            }
        )

        _ = try! await pool.getOrCreate(
            mediaId: "one",
            source: makeSource("one")
        )

        _ = try! await pool.getOrCreate(
            mediaId: "two",
            source: makeSource("two")
        )

        await pool.updatePinnedIds([
            "one",
            "two"
        ])

        do {
            _ = try await pool.getOrCreate(
                mediaId: "three",
                source: makeSource("three")
            )

            XCTFail("Expected capacityExceeded")

        } catch let error as PlayerPoolError {

            XCTAssertEqual(
                error,
                .capacityExceeded
            )

        } catch {

            XCTFail(
                "Unexpected error: \(error)"
            )
        }
    }

    func testConcurrentRequestsForSameMediaDoNotCreateDuplicates()
        async throws
    {

        var created: [FakePlayerEngine] = []

        let pool = PlayerPool(
            configuration: PlayerPoolConfiguration(
                maxPlayers: 3,
                maxIdlePlayers: 2
            ),
            factory: {
                let engine = FakePlayerEngine()
                created.append(engine)
                return engine
            }
        )

        // Build the immutable source on the test actor before spawning
        // child tasks; async-let expressions must not capture XCTest self.
        let source = makeSource("same")

        async let first = pool.getOrCreate(
            mediaId: "same",
            source: source
        )

        async let second = pool.getOrCreate(
            mediaId: "same",
            source: source
        )

        let firstPlayer = try await first
        let secondPlayer = try await second

        XCTAssertEqual(created.count, 1)
        XCTAssertTrue(
            firstPlayer.engine === secondPlayer.engine
        )
    }

    func testReleaseAllReleasesEveryPlayer() async {

        var created: [FakePlayerEngine] = []

        let pool = PlayerPool(
            configuration: PlayerPoolConfiguration(
                maxPlayers: 3,
                maxIdlePlayers: 2
            ),
            factory: {
                let engine = FakePlayerEngine()
                created.append(engine)
                return engine
            }
        )

        _ = try! await pool.getOrCreate(
            mediaId: "one",
            source: makeSource("one")
        )

        _ = try! await pool.getOrCreate(
            mediaId: "two",
            source: makeSource("two")
        )

        await pool.releaseAll()

        XCTAssertEqual(
            created.reduce(0) {
                $0 + $1.releaseCount
            },
            2
        )

        let activeCount = pool.activeCount
        let idleCount = pool.idleCount
        let retainedPlayerCount = pool.retainedPlayerCount

        XCTAssertEqual(activeCount, 0)
        XCTAssertEqual(idleCount, 0)
        XCTAssertEqual(retainedPlayerCount, 0)
    }
}
