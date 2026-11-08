import XCTest
@testable import CorePlayerEngine

@MainActor
final class PlayerPoolTests: XCTestCase {

    @MainActor
    private final class ManualAsyncGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var isWaiting = false

        func wait() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                isWaiting = true
            }
        }

        func resume() {
            guard let continuation else {
                return
            }

            self.continuation = nil
            isWaiting = false
            continuation.resume()
        }
    }

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

        var loadGate: ManualAsyncGate?
        var stopGate: ManualAsyncGate?
        var failLoad = false

        enum FakeEngineError: Error {
            case loadFailed
        }

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

            // A manually controlled gate lets lifecycle tests hold a load
            // across releaseAll() without relying on timing or sleeps.
            if let loadGate {
                await loadGate.wait()
            } else {
                await Task.yield()
            }

            if failLoad {
                throw FakeEngineError.loadFailed
            }

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

            if let stopGate {
                await stopGate.wait()
            }

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

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if condition() {
                return
            }

            await Task.yield()
        }

        XCTFail(
            "Timed out waiting for the expected pool lifecycle state.",
            file: file,
            line: line
        )
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

    func testFailedLoadDiscardsTerminallyReleasedEngine() async throws {
        var created: [FakePlayerEngine] = []

        let pool = PlayerPool(
            configuration: PlayerPoolConfiguration(
                maxPlayers: 2,
                maxIdlePlayers: 1
            ),
            factory: {
                let engine = FakePlayerEngine()
                engine.failLoad = created.isEmpty
                created.append(engine)
                return engine
            }
        )

        do {
            _ = try await pool.getOrCreate(
                mediaId: "first",
                source: makeSource("first")
            )
            XCTFail("Expected the first engine load to fail.")
        } catch FakePlayerEngine.FakeEngineError.loadFailed {
            // Expected. The failed engine must be disposed, not cached.
        }

        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created[0].releaseCount, 1)
        XCTAssertEqual(pool.retainedPlayerCount, 0)
        XCTAssertEqual(pool.idleCount, 0)

        let second = try await pool.getOrCreate(
            mediaId: "second",
            source: makeSource("second")
        )

        XCTAssertEqual(created.count, 2)
        XCTAssertTrue(second.engine === created[1])
        XCTAssertEqual(created[0].releaseCount, 1)
    }

    func testReleaseAllWaitsForInFlightLoadAndReleasesExactlyOnce() async throws {
        let gate = ManualAsyncGate()
        let engine = FakePlayerEngine()
        engine.loadGate = gate

        let pool = PlayerPool(
            configuration: PlayerPoolConfiguration(
                maxPlayers: 2,
                maxIdlePlayers: 1
            ),
            factory: { engine }
        )

        let source = makeSource("loading")
        let acquisition = Task {
            try await pool.getOrCreate(
                mediaId: "loading",
                source: source
            )
        }

        await waitUntil { gate.isWaiting }

        let drain = Task { @MainActor in
            await pool.releaseAll()
        }

        await waitUntil { pool.isDraining }
        XCTAssertEqual(engine.releaseCount, 0)

        // The fake intentionally ignores task cancellation until its load
        // completes. The pool must wait, then perform exactly one terminal
        // release itself.
        gate.resume()
        await drain.value

        do {
            _ = try await acquisition.value
            XCTFail("An acquisition invalidated by releaseAll() must not succeed.")
        } catch is CancellationError {
            // Expected cancellation from the pool drain.
        }

        XCTAssertEqual(engine.releaseCount, 1)
        XCTAssertEqual(pool.activeCount, 0)
        XCTAssertEqual(pool.idleCount, 0)
        XCTAssertEqual(pool.retainedPlayerCount, 0)
        XCTAssertEqual(pool.inFlightCreationCount, 0)
        XCTAssertFalse(pool.isDraining)
    }

    func testReleaseAllWaitsForInFlightStopAndConcurrentCallersJoinDrain() async throws {
        let gate = ManualAsyncGate()
        let engine = FakePlayerEngine()
        engine.stopGate = gate

        let pool = PlayerPool(
            configuration: PlayerPoolConfiguration(
                maxPlayers: 2,
                maxIdlePlayers: 1
            ),
            factory: { engine }
        )

        _ = try await pool.getOrCreate(
            mediaId: "one",
            source: makeSource("one")
        )

        let release = Task { @MainActor in
            await pool.release(mediaId: "one")
        }

        await waitUntil { gate.isWaiting }

        let firstDrain = Task { @MainActor in
            await pool.releaseAll()
        }

        await waitUntil { pool.isDraining }

        var secondDrainStarted = false
        var secondDrainCompleted = false

        let secondDrain = Task { @MainActor in
            secondDrainStarted = true
            await pool.releaseAll()
            secondDrainCompleted = true
        }

        await waitUntil { secondDrainStarted }
        XCTAssertFalse(secondDrainCompleted)
        XCTAssertEqual(engine.releaseCount, 0)

        // stop() must complete before releaseAll() can call release().
        gate.resume()

        await release.value
        await firstDrain.value
        await secondDrain.value

        XCTAssertTrue(secondDrainCompleted)
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertEqual(engine.releaseCount, 1)
        XCTAssertEqual(pool.activeCount, 0)
        XCTAssertEqual(pool.idleCount, 0)
        XCTAssertEqual(pool.retainedPlayerCount, 0)
        XCTAssertFalse(pool.isDraining)
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
