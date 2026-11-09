import Foundation
@MainActor
public final class PlayerManager {
    
    public static let shared = PlayerManager()
    
    private let pool: PlayerPool
    
    private let orchestrator: PlaybackOrchestrator
    
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
    public private(set) var isSustainedLowBandwidth = false
    private var poolEnvironment = PlayerPoolEnvironment(
        physicalMemoryMB: Int(ProcessInfo.processInfo.physicalMemory / (1_024 * 1_024))
    )
    public private(set) var activeMediaId: String?
    
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
        self.networkMonitor = networkMonitor
        self.networkRecovery = NetworkRecoveryCoordinator(
            network: networkMonitor,
            playback: orchestrator
        )
    }
    
    public func start() {

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
                Task {
                    await self?.pause()
                }
            },
            onAppForegrounded: { [weak self] in
                // Recovery coordinator handles transport recovery.
                // Do not automatically resume user-paused media.
                _ = self
            }
        )
    }
    
    public func play(
        mediaId: String,
        source: MediaSource,
        title: String? = nil,
        artist: String? = nil,
        contentType: PlaybackContentType = .onDemand
    ) async throws {
        
        mediaSessionProvider.configureNowPlaying(
            title: title,
            artist: artist
        )
        
        audioSession.request()
        
        try await orchestrator.play(
            mediaId: mediaId,
            source: source
        )

        activeMediaId = orchestrator.activeMediaId
        guard activeMediaId == mediaId else { return }
        await startBitrateMonitoring(
            mediaId: mediaId,
            contentType: contentType
        )
    }
    
    public func pause() async {

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
    
    private func startBitrateMonitoring(
        mediaId: String,
        contentType: PlaybackContentType
    ) async {
        bitrateMonitoringGeneration &+= 1
        let generation = bitrateMonitoringGeneration

        guard activeMediaId == mediaId else { return }

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
              activeMediaId == mediaId,
              let provider = await orchestrator.avPlayerProvider(mediaId: mediaId),
              generation == bitrateMonitoringGeneration,
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

        bitrateTask = Task { @MainActor [weak self] in
            for await event in events {
                guard !Task.isCancelled,
                      let self,
                      self.bitrateMonitoringGeneration == generation,
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
