import XCTest
@testable import CorePlayerEngine

@MainActor
final class PlaybackOrchestratorTests: XCTestCase {

    // MARK: - Synchronization

    @MainActor
    final class ManualAsyncGate {
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

    // MARK: - Test Engine

    final class FakePlayerEngine: PlayerEngine {

        private let stateStream: AsyncStream<PlayerState>
        private let eventStream: AsyncStream<PlayerEvent>

        private var stateContinuation: AsyncStream<PlayerState>.Continuation?
        private var eventContinuation: AsyncStream<PlayerEvent>.Continuation?

        private var stateValue: PlayerState = .idle
        private var resumeIntent = false

        var stopGate: ManualAsyncGate?
        var playGate: ManualAsyncGate?
        var loadGate: ManualAsyncGate?

        private(set) var operationLog: [String] = []
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
            operationLog.append("load.begin")

            if let loadGate {
                self.loadGate = nil
                await loadGate.wait()
            }

            stateValue = .ready
            stateContinuation?.yield(.ready)
            operationLog.append("load.end")
        }

        func load(
            mediaId: String,
            source: MediaSource
        ) async throws {
            loadedMediaIds.append(mediaId)
            operationLog.append("load.media.\(mediaId)")
            try await load(source)
        }

        var shouldResumeAfterInterruption: Bool {
            get async { resumeIntent }
        }

        func simulateNetworkLoss(resumePlayback: Bool) {
            resumeIntent = resumePlayback
            stateValue = .reconnecting
            stateContinuation?.yield(.reconnecting)
        }

        func play() async throws {
            playCount += 1
            resumeIntent = true
            operationLog.append("play.begin")

            if let playGate {
                self.playGate = nil
                await playGate.wait()
            }

            stateValue = .playing
            stateContinuation?.yield(.playing)
            operationLog.append("play.end")
        }

        func pause() async throws {
            pauseCount += 1
            resumeIntent = false
            operationLog.append("pause")
            stateValue = .paused
            stateContinuation?.yield(.paused)
        }

        func seek(to seconds: TimeInterval) async throws {}

        func stop() async throws {
            stopCount += 1
            operationLog.append("stop.begin")

            if let stopGate {
                self.stopGate = nil
                await stopGate.wait()
            }

            stateValue = .idle
            stateContinuation?.yield(.idle)
            operationLog.append("stop.end")
        }

        func release() async throws {
            releaseCount += 1
            operationLog.append("release")
            stateStreamContinuationFinish()
        }

        private func stateStreamContinuationFinish() {
            stateContinuation?.finish()
            eventContinuation?.finish()
        }

        var currentState: PlayerState {
            get async {
                stateValue
            }
        }

        func notifyNetworkLost() async {
            operationLog.append("network.lost")
        }

        func notifyRecoveryExhausted() async {
            operationLog.append("recovery.exhausted")
        }

        var currentTime: TimeInterval {
            get async { 0 }
        }

        var duration: TimeInterval? {
            get async { nil }
        }
    }

    struct NoOpStreamingPipeline: StreamingPipeline {
        func warm(
            mediaId: String,
            source: MediaSource,
            priority: WarmPriority
        ) async {}
    }

    @MainActor
    final class GatedStreamingPipeline: StreamingPipeline {
        let gate: ManualAsyncGate
        private(set) var didStartWarm = false

        init(gate: ManualAsyncGate) {
            self.gate = gate
        }

        func warm(
            mediaId: String,
            source: MediaSource,
            priority: WarmPriority
        ) async {
            didStartWarm = true
            await gate.wait()
        }
    }

    // MARK: - Helpers

    private func makeSource(_ mediaId: String) -> MediaSource {
        MediaSource(
            url: URL(string: "https://example.com/\(mediaId).mp4")!,
            type: .auto
        )
    }

    private func makeOrchestrator(
        maxPlayers: Int = 3
    ) -> (
        orchestrator: PlaybackOrchestrator,
        pool: PlayerPool,
        engines: () -> [FakePlayerEngine]
    ) {
        var engines: [FakePlayerEngine] = []

        let pool = PlayerPool(
            configuration: PlayerPoolConfiguration(
                maxPlayers: maxPlayers,
                maxIdlePlayers: maxPlayers
            ),
            factory: {
                let engine = FakePlayerEngine()
                engines.append(engine)
                return engine
            }
        )

        return (
            PlaybackOrchestrator(
                pool: pool,
                streamingPipeline: NoOpStreamingPipeline()
            ),
            pool,
            { engines }
        )
    }

    private func waitUntil(
        timeoutIterations: Int = 10_000,
        condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<timeoutIterations {
            if condition() {
                return
            }

            await Task.yield()
        }

        XCTFail(
            "Condition was not satisfied within the test window.",
            file: file,
            line: line
        )
    }

    func testPlayerEngineLookupReturnsOnlyTheManagedMediaIdentity() async throws {
        let (orchestrator, _, enginesProvider) = makeOrchestrator()

        try await orchestrator.play(
            mediaId: "visible",
            source: makeSource("visible")
        )

        let engine = await orchestrator.playerEngine(for: "visible")
        let managedEngine = try XCTUnwrap(engine)
        XCTAssertTrue(managedEngine === enginesProvider()[0])

        let missingEngine = await orchestrator.playerEngine(for: "missing")
        XCTAssertNil(missingEngine)
    }

    func testEngineReadyCallbackRunsBeforeVisibleCacheWarmCompletes() async throws {
        let warmGate = ManualAsyncGate()
        let streaming = GatedStreamingPipeline(gate: warmGate)
        let engine = FakePlayerEngine()
        let pool = PlayerPool(
            configuration: PlayerPoolConfiguration(maxPlayers: 2, maxIdlePlayers: 1),
            factory: { engine }
        )
        let orchestrator = PlaybackOrchestrator(
            pool: pool,
            streamingPipeline: streaming
        )
        var callbackEngine: (any PlayerEngine)?

        let playTask = Task { @MainActor in
            try await orchestrator.play(
                mediaId: "visible",
                source: makeSource("visible"),
                onEngineReady: { readyEngine in
                    callbackEngine = readyEngine
                }
            )
        }

        await waitUntil {
            streaming.didStartWarm && callbackEngine != nil
        }

        let handedOffEngine = try XCTUnwrap(callbackEngine)
        XCTAssertTrue(handedOffEngine === engine)
        XCTAssertEqual(orchestrator.activeMediaId, "visible")

        warmGate.resume()
        try await playTask.value
    }

    // MARK: - Per-Player Command Ordering

    func testStopAndReplayOnSamePlayerAreSerialized() async throws {
        let (orchestrator, pool, enginesProvider) = makeOrchestrator()

        try await orchestrator.play(
            mediaId: "same",
            source: makeSource("same")
        )

        let engine = try XCTUnwrap(enginesProvider().first)
        let stopGate = ManualAsyncGate()
        let playGate = ManualAsyncGate()

        engine.stopGate = stopGate

        let stopTask = Task { @MainActor in
            await orchestrator.stopCurrent()
        }

        await waitUntil {
            stopGate.isWaiting
        }

        engine.playGate = playGate

        let replaySource = makeSource("same")
        let replayTask = Task { @MainActor in
            try await orchestrator.play(
                mediaId: "same",
                source: replaySource
            )
        }

        // The replay queues behind stop() for the same ManagedPlayer.
        let maybeManaged = await pool.get(mediaId: "same")
        let managed = try XCTUnwrap(maybeManaged)
        await waitUntil {
            managed.pendingOperationCount == 2
        }

        stopGate.resume()

        await waitUntil {
            playGate.isWaiting
        }

        let stopEnd = try XCTUnwrap(
            engine.operationLog.firstIndex(of: "stop.end")
        )
        let replayStart = try XCTUnwrap(
            engine.operationLog.lastIndex(of: "play.begin")
        )

        XCTAssertLessThan(stopEnd, replayStart)

        // Wait for stopCurrent() itself to finish while the newer play
        // remains suspended. Its stale completion must not clear ownership.
        await stopTask.value
        XCTAssertEqual(orchestrator.activeMediaId, "same")

        playGate.resume()

        try await replayTask.value

        XCTAssertEqual(orchestrator.activeMediaId, "same")
        let finalState = await engine.currentState
        XCTAssertEqual(finalState, .playing)
    }

    // MARK: - Pending Play Invalidation

    func testInvalidatingPendingPlayDuringLoadPreventsTransportStart() async {
        let loadGate = ManualAsyncGate()
        let engine = FakePlayerEngine()
        engine.loadGate = loadGate
        let pool = PlayerPool(
            configuration: PlayerPoolConfiguration(maxPlayers: 2, maxIdlePlayers: 1),
            factory: { engine }
        )
        let orchestrator = PlaybackOrchestrator(
            pool: pool,
            streamingPipeline: NoOpStreamingPipeline()
        )

        let playTask = Task { @MainActor in
            do {
                try await orchestrator.play(
                    mediaId: "stale-load",
                    source: makeSource("stale-load")
                )
                return false
            } catch is CancellationError {
                return true
            } catch {
                XCTFail("Unexpected play error: \(error)")
                return false
            }
        }

        await waitUntil { loadGate.isWaiting }
        orchestrator.invalidatePendingPlaybackRequest()
        loadGate.resume()

        let wasCancelled = await playTask.value
        XCTAssertTrue(wasCancelled)
        XCTAssertNil(orchestrator.activeMediaId)
        XCTAssertEqual(engine.playCount, 0)
    }

    func testInvalidatingPendingPlayAfterTransportStartsQueuesIdentitySafePause() async {
        let playGate = ManualAsyncGate()
        let engine = FakePlayerEngine()
        engine.playGate = playGate
        let pool = PlayerPool(
            configuration: PlayerPoolConfiguration(maxPlayers: 2, maxIdlePlayers: 1),
            factory: { engine }
        )
        let orchestrator = PlaybackOrchestrator(
            pool: pool,
            streamingPipeline: NoOpStreamingPipeline()
        )

        let playTask = Task { @MainActor in
            do {
                try await orchestrator.play(
                    mediaId: "stale-transport",
                    source: makeSource("stale-transport")
                )
                return false
            } catch is CancellationError {
                return true
            } catch {
                XCTFail("Unexpected play error: \(error)")
                return false
            }
        }

        await waitUntil { playGate.isWaiting }
        orchestrator.invalidatePendingPlaybackRequest()
        playGate.resume()

        let wasCancelled = await playTask.value
        XCTAssertTrue(wasCancelled)
        await waitUntil { engine.pauseCount == 1 }

        XCTAssertNil(orchestrator.activeMediaId)
        let finalState = await engine.currentState
        XCTAssertEqual(finalState, .paused)
    }

    // MARK: - Recovery Supersession

    func testRecoveryDoesNotAutoPlayWhenPreviousPlaybackIntentWasPaused()
        async throws {
        let (orchestrator, _, enginesProvider) = makeOrchestrator()

        try await orchestrator.play(
            mediaId: "paused",
            source: makeSource("paused")
        )

        let engine = try XCTUnwrap(enginesProvider().first)
        engine.simulateNetworkLoss(resumePlayback: false)

        try await orchestrator.recoverActivePlayback()

        XCTAssertEqual(
            engine.playCount,
            1,
            "Recovery must not issue play when the user had paused."
        )
        let recoveredState = await engine.currentState
        XCTAssertEqual(recoveredState, .ready)
    }

    func testRecoveryResumesWhenPreviousPlaybackIntentWasActive()
        async throws {
        let (orchestrator, _, enginesProvider) = makeOrchestrator()

        try await orchestrator.play(
            mediaId: "playing",
            source: makeSource("playing")
        )

        let engine = try XCTUnwrap(enginesProvider().first)
        engine.simulateNetworkLoss(resumePlayback: true)

        try await orchestrator.recoverActivePlayback()

        XCTAssertEqual(engine.playCount, 2)
        let recoveredState = await engine.currentState
        XCTAssertEqual(recoveredState, .playing)
    }

    func testNewPlaySupersedesSuspendedRecoveryBeforeItCanRestartOldMedia()
        async throws {
        let (orchestrator, pool, enginesProvider) = makeOrchestrator()

        try await orchestrator.play(
            mediaId: "first",
            source: makeSource("first")
        )

        let firstEngine = try XCTUnwrap(enginesProvider().first)
        let recoveryGate = ManualAsyncGate()
        firstEngine.loadGate = recoveryGate

        let recovery = Task { @MainActor in
            do {
                try await orchestrator.recoverActivePlayback()
                return false
            } catch is CancellationError {
                return true
            } catch {
                XCTFail("Unexpected recovery error: \(error)")
                return false
            }
        }

        await waitUntil {
            recoveryGate.isWaiting
        }

        let secondSource = makeSource("second")
        let secondPlay = Task { @MainActor in
            try await orchestrator.play(
                mediaId: "second",
                source: secondSource
            )
        }

        // The newer play invalidates recovery immediately and queues its
        // pause behind the suspended recovery load on the same engine.
        let maybeFirstManaged = await pool.get(mediaId: "first")
        let firstManaged = try XCTUnwrap(maybeFirstManaged)
        await waitUntil {
            firstManaged.pendingOperationCount == 2
        }

        recoveryGate.resume()

        let recoveryWasCancelled = await recovery.value
        XCTAssertTrue(recoveryWasCancelled)
        try await secondPlay.value

        XCTAssertEqual(orchestrator.activeMediaId, "second")
        XCTAssertEqual(
            firstEngine.operationLog.filter { $0 == "play.begin" }.count,
            1,
            "Recovery must not issue a second play after it becomes stale."
        )

        let engines = enginesProvider()
        XCTAssertEqual(engines.count, 2)
        XCTAssertEqual(engines[1].playCount, 1)
    }
}
