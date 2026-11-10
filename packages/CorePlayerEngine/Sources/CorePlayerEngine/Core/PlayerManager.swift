import Foundation
@MainActor
public final class PlayerManager: VideoPlaybackTarget {
    
    public static let shared = PlayerManager()
    
    private let pool: PlayerPool
    
    private let orchestrator: PlaybackOrchestrator

    private let streamingPipeline: StreamingPipeline
    
    private let networkMonitor: NetworkConnectivityProviding
    
    private let networkRecovery: NetworkRecoveryCoordinator
    
    private let environmentManager = EnvironmentManager()
    private let poolEnvironmentMonitor = PlayerPoolEnvironmentMonitor()
    private let audioSession = AudioSessionManager()
    private let mediaSessionProvider = MediaSessionProvider()
    private let bitrateController = DynamicBitrateController()
    private var bitrateTask: Task<Void, Never>?
    private var monitoredBitrateEngine: (any AVPlayerProviding)?
    private var monitoredBitrateContentType: PlaybackContentType?
    private var latestBitrateProgress: PlaybackProgress?
    private var bitrateMonitoringGeneration: UInt64 = 0
    private var lowBandwidthDetector = SustainedLowBandwidthDetector()
    private var activeContentType: PlaybackContentType = .onDemand
    private var lifecycleState = PlaybackLifecycleState()
    private var backgroundTransitionTask: Task<Void, Never>?
    public private(set) var isSustainedLowBandwidth = false
    private var poolEnvironment = PlayerPoolEnvironment(
        physicalMemoryMB: Int(ProcessInfo.processInfo.physicalMemory / (1_024 * 1_024))
    )
    public private(set) var activeMediaId: String?
    private var hasStarted = false
    
    public init() {
        
        let cacheDirectory =
            FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            )[0]
            .appendingPathComponent(
                "Estatia/PlayerMediaCache/v1",
                isDirectory: true
            )
        
        let cacheStore =
            FileMediaCacheStore(
                rootDirectory:
                    cacheDirectory
            )
        
        let cacheConfiguration =
            PlayerCacheConfiguration(
                store:
                    cacheStore
            )
        
        let pool =
            PlayerPool(
                factory: {
                    PlayerEngineFactory.make(
                        cacheConfiguration:
                            cacheConfiguration
                    )
                }
            )
        
        let cacheWarmer =
            MediaCacheWarmer(
                store:
                    cacheStore
            )

        let streamingPipeline =
            DefaultStreamingPipeline(
                cacheWarmer:
                    cacheWarmer
            )
        
        let orchestrator =
            PlaybackOrchestrator(
                pool: pool,
                streamingPipeline: streamingPipeline
            )
        
        let networkMonitor = NetworkConnectivityMonitor()
        
        self.pool = pool
        self.orchestrator = orchestrator
        self.streamingPipeline = streamingPipeline
        self.networkMonitor = networkMonitor
        self.networkRecovery = NetworkRecoveryCoordinator(
            network: networkMonitor,
            playback: orchestrator
        )
    }
    
    public func start() {
        guard !hasStarted else { return }
        hasStarted = true

        poolEnvironmentMonitor.start { [weak self] environment in
            guard let self else { return }
            self.poolEnvironment = environment
            self.pool.updateEnvironment(environment)
            self.applyCurrentBitratePolicy()
        }

        networkRecovery.onNetworkSnapshotChange = { [weak self] _ in
            self?.applyCurrentBitratePolicy()
        }
        networkRecovery.start()
        
        environmentManager.start(
            onAppBackgrounded: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.beginAppBackgroundTransition()
                }
            },
            onAppForegrounded: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.handleAppForegrounded()
                }
            }
        )
    }
    
    /// Builds a feed coordinator that shares this manager's player pool,
    /// network recovery, audio session and disk cache.
    public func makeFeedPlaybackCoordinator(
        policy: VideoPlaybackPolicy = VideoPlaybackPolicy(),
        onPlaybackReady: @escaping @MainActor @Sendable (String) async -> Void = { _ in }
    ) -> VideoPlaybackCoordinator {
        VideoPlaybackCoordinator(
            playback: self,
            streamingPipeline: streamingPipeline,
            policy: policy,
            onPlaybackReady: onPlaybackReady
        )
    }

    /// VideoPlaybackTarget adapter. Route feed playback through PlayerManager
    /// so lifecycle, audio-session and bitrate policies remain authoritative.
    public func play(
        mediaId: String,
        source: MediaSource
    ) async throws {
        try await play(mediaId: mediaId, source: source, title: nil, artist: nil)
    }

    public func invalidatePendingPlaybackRequest() {
        orchestrator.invalidatePendingPlaybackRequest()
    }

    public func updateComposedMedia(_ mediaIds: Set<String>) async {
        await orchestrator.updateComposedMedia(mediaIds)
    }

    public func isMediaActive(_ mediaId: String) -> Bool {
        orchestrator.isMediaActive(mediaId)
    }

    public func pauseCurrent() async {
        await pause()
    }

    public func play(
        mediaId: String,
        source: MediaSource,
        title: String? = nil,
        artist: String? = nil,
        contentType: PlaybackContentType = .onDemand
    ) async throws {
        
        // A new explicit play request supersedes any pending lifecycle resume.
        let lifecycleGeneration = lifecycleState.invalidateForExplicitCommand()
        mediaSessionProvider.configureNowPlaying(
            title: title,
            artist: artist
        )
        
        audioSession.request()
        
        try await orchestrator.play(
            mediaId: mediaId,
            source: source
        )

        guard lifecycleState.isCurrent(lifecycleGeneration) else {
            throw CancellationError()
        }

        activeMediaId = orchestrator.activeMediaId
        guard activeMediaId == mediaId else { return }
        activeContentType = contentType
        await startBitrateMonitoring(
            mediaId: mediaId,
            contentType: contentType,
            lifecycleGeneration: lifecycleGeneration
        )
    }
    
    public func pause() async {
        let lifecycleGeneration = lifecycleState.invalidateForExplicitCommand()
        await pausePlayback(lifecycleGeneration: lifecycleGeneration)
    }

    /// Starts and retains the background operation so foreground recovery
    /// cannot race a still-suspended pause command.
    private func beginAppBackgroundTransition() {
        guard !lifecycleState.isBackgrounded else { return }

        let generation = lifecycleState.beginBackgroundTransition()
        let mediaId = activeMediaId

        backgroundTransitionTask = Task { @MainActor [weak self] in
            await self?.handleAppBackgrounded(
                generation: generation,
                mediaId: mediaId
            )
        }
    }

    private func handleAppBackgrounded(
        generation: UInt64,
        mediaId: String?
    ) async {
        let wasPlaying = await orchestrator.isCurrentlyPlaying()

        guard lifecycleState.recordBackgroundPlayback(
                wasPlaying: wasPlaying,
                generation: generation
              ),
              activeMediaId == mediaId
        else {
            return
        }

        await pausePlayback(lifecycleGeneration: generation)
    }

    private func handleAppForegrounded() async {
        // The background operation includes an asynchronous playback snapshot
        // and pause. Await it before attempting resume to preserve command order.
        if let backgroundTransitionTask {
            await backgroundTransitionTask.value
            if !lifecycleState.isBackgrounded {
                self.backgroundTransitionTask = nil
            }
        }

        let transition = lifecycleState.beginForegroundTransition()
        guard transition.shouldResume,
              let mediaId = activeMediaId
        else {
            return
        }

        do {
            try await orchestrator.resumeCurrent()

            guard lifecycleState.isCurrent(transition.generation),
                  activeMediaId == mediaId
            else {
                return
            }

            audioSession.request()
            await startBitrateMonitoring(
                mediaId: mediaId,
                contentType: activeContentType,
                lifecycleGeneration: transition.generation
            )
            lifecycleState.finishForegroundResume(
                generation: transition.generation
            )
        } catch {
            // A newer explicit pause/play command owns the audio session now.
            // Never let this stale continuation abandon that newer session.
            guard lifecycleState.isCurrent(transition.generation),
                  activeMediaId == mediaId
            else {
                return
            }

            audioSession.abandon()
            lifecycleState.finishForegroundResume(
                generation: transition.generation
            )
        }
    }

    private func pausePlayback(
        lifecycleGeneration: UInt64
    ) async {

        bitrateMonitoringGeneration &+= 1
        bitrateTask?.cancel()
        bitrateTask = nil
        if let monitoredBitrateEngine {
            bitrateController.reset(for: monitoredBitrateEngine)
            self.monitoredBitrateEngine = nil
        }
        monitoredBitrateContentType = nil
        latestBitrateProgress = nil
        await orchestrator.pauseCurrent()

        // A newer play, pause, or foreground transition may have claimed the
        // audio session while the transport pause was suspended.
        guard lifecycleState.isCurrent(lifecycleGeneration) else { return }
        audioSession.abandon()
    }
    
    public func preload(
        mediaId: String,
        source: MediaSource
    ) async {
        
        await orchestrator.preload(
            mediaId: mediaId,
            source: source
        )
    }
    
    public func observeState(
        mediaId: String
    ) async -> AsyncStream<PlayerState>? {
        
        await orchestrator.observeState(
            mediaId: mediaId
        )
    }
    
    public func playerEngine(for mediaId: String) async -> (any PlayerEngine)? {
        await orchestrator.playerEngine(for: mediaId)
    }

    private func startBitrateMonitoring(
        mediaId: String,
        contentType: PlaybackContentType,
        lifecycleGeneration: UInt64
    ) async {
        bitrateMonitoringGeneration &+= 1
        let generation = bitrateMonitoringGeneration

        guard lifecycleState.isCurrent(lifecycleGeneration),
              activeMediaId == mediaId
        else {
            return
        }

        _ = lowBandwidthDetector.reset()
        isSustainedLowBandwidth = false

        bitrateTask?.cancel()
        bitrateTask = nil

        if let previousEngine = monitoredBitrateEngine {
            bitrateController.reset(for: previousEngine)
        }

        monitoredBitrateEngine = nil
        monitoredBitrateContentType = nil
        latestBitrateProgress = nil

        guard let events = await orchestrator.observeEvents(mediaId: mediaId),
              generation == bitrateMonitoringGeneration,
              lifecycleState.isCurrent(lifecycleGeneration),
              activeMediaId == mediaId,
              let provider = await orchestrator.avPlayerProvider(mediaId: mediaId),
              generation == bitrateMonitoringGeneration,
              lifecycleState.isCurrent(lifecycleGeneration),
              activeMediaId == mediaId
        else {
            return
        }

        monitoredBitrateEngine = provider
        monitoredBitrateContentType = contentType

        await orchestrator.notifySustainedLowBandwidth(
            mediaId: mediaId,
            isSustained: false
        )

        guard generation == bitrateMonitoringGeneration,
              lifecycleState.isCurrent(lifecycleGeneration),
              activeMediaId == mediaId
        else {
            return
        }

        bitrateTask = Task { @MainActor [weak self] in
            for await event in events {
                guard !Task.isCancelled,
                      let self,
                      self.bitrateMonitoringGeneration == generation,
                      self.lifecycleState.isCurrent(lifecycleGeneration),
                      self.activeMediaId == mediaId
                else {
                    return
                }

                guard case let .progress(progress) = event else {
                    continue
                }

                self.latestBitrateProgress = progress
                await self.updateSustainedLowBandwidth(
                    throughputBps: provider.observedBitrateBps,
                    mediaId: mediaId
                )
                self.applyCurrentBitratePolicy()
            }
        }
    }

    /// Updates the warning only when the detector crosses a threshold.
    /// Throughput is sampled alongside playback progress, not on every
    /// environment notification, to avoid counting the same access-log value
    /// multiple times between media samples.
    private func updateSustainedLowBandwidth(
        throughputBps: Double?,
        mediaId: String
    ) async {
        guard activeMediaId == mediaId else { return }

        let changed = lowBandwidthDetector.record(
            throughputBps: throughputBps
        )
        guard changed else { return }

        let nextState = lowBandwidthDetector.isSustainedLowBandwidth
        isSustainedLowBandwidth = nextState
        await orchestrator.notifySustainedLowBandwidth(
            mediaId: mediaId,
            isSustained: nextState
        )
    }

    /// Re-evaluates the current ceiling whenever progress or the surrounding
    /// network/resource environment changes. A progress sample is required so
    /// buffer health is based on measured playback state rather than a guess.
    private func applyCurrentBitratePolicy() {
        guard let provider = monitoredBitrateEngine,
              let contentType = monitoredBitrateContentType,
              let progress = latestBitrateProgress
        else {
            return
        }

        let loadedEnd = progress.buffered ?? progress.currentTime
        let bufferAhead = max(0, loadedEnd - progress.currentTime)
        let snapshot = networkMonitor.currentSnapshot
        let environment = poolEnvironment

        let input = BitratePolicyInput(
            estimatedThroughputBps: provider.observedBitrateBps,
            bufferAheadSeconds: bufferAhead,
            thermalState: environment.thermalState,
            isLowPowerModeEnabled: environment.isLowPowerModeEnabled,
            isMetered: snapshot.isExpensive,
            isConstrained: snapshot.isConstrained,
            contentType: contentType,
            isStartup: progress.currentTime < 5
        )

        bitrateController.apply(input, to: provider)
    }

    public func shutdown() async {

        _ = lifecycleState.invalidateForExplicitCommand()
        backgroundTransitionTask?.cancel()
        backgroundTransitionTask = nil

        if let activeMediaId {
            await orchestrator.notifySustainedLowBandwidth(
                mediaId: activeMediaId,
                isSustained: false
            )
        }
        _ = lowBandwidthDetector.reset()
        isSustainedLowBandwidth = false
        
        bitrateMonitoringGeneration &+= 1
        networkRecovery.onNetworkSnapshotChange = nil
        networkRecovery.stop()
        poolEnvironmentMonitor.stop()
        bitrateTask?.cancel()
        bitrateTask = nil
        if let monitoredBitrateEngine {
            bitrateController.reset(for: monitoredBitrateEngine)
            self.monitoredBitrateEngine = nil
        }
        monitoredBitrateContentType = nil
        latestBitrateProgress = nil
        bitrateController.resetAll()

        audioSession.cleanup()
        
        await orchestrator.shutdown()
        
        environmentManager.stop()
        
        activeMediaId = nil
    }
}
