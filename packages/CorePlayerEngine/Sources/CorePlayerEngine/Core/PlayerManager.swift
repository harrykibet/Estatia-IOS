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
            self?.poolEnvironment = environment
            self?.pool.updateEnvironment(environment)
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
        await startBitrateMonitoring(
            mediaId: mediaId,
            contentType: contentType
        )
    }
    
    public func pause() async {

        bitrateTask?.cancel()
        bitrateTask = nil
        if let monitoredBitrateEngine {
            bitrateController.reset(for: monitoredBitrateEngine)
            self.monitoredBitrateEngine = nil
        }
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
        bitrateTask?.cancel()
        bitrateTask = nil

        if let previousEngine = monitoredBitrateEngine {
            bitrateController.reset(for: previousEngine)
        }

        guard let events = await orchestrator.observeEvents(mediaId: mediaId),
              let provider = await orchestrator.avPlayerProvider(mediaId: mediaId)
        else {
            monitoredBitrateEngine = nil
            return
        }

        monitoredBitrateEngine = provider

        let controller = bitrateController
        let network = networkMonitor

        bitrateTask = Task { @MainActor [weak self] in
            for await event in events {
                guard !Task.isCancelled,
                      let self,
                      self.activeMediaId == mediaId
                else {
                    return
                }

                guard case let .progress(progress) = event else {
                    continue
                }

                let snapshot = network.currentSnapshot
                let loadedEnd = progress.buffered ?? progress.currentTime
                let bufferAhead = max(0, loadedEnd - progress.currentTime)
                let environment = self.poolEnvironment

                // AVPlayer access-log observations provide a device-measured
                // bitrate estimate. When no access-log sample exists, the
                // policy uses its conservative default throughput.
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

                controller.apply(input, to: provider)
            }
        }
    }

    public func shutdown() async {
        
        networkRecovery.stop()
        poolEnvironmentMonitor.stop()
        bitrateTask?.cancel()
        bitrateTask = nil
        if let monitoredBitrateEngine {
            bitrateController.reset(for: monitoredBitrateEngine)
            self.monitoredBitrateEngine = nil
        }
        bitrateController.resetAll()

        audioSession.cleanup()
        
        await orchestrator.shutdown()
        
        environmentManager.stop()
        
        activeMediaId = nil
    }
}
