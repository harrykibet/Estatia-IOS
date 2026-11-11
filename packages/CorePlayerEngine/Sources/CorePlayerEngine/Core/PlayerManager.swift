import CoreAnalytics
import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
public final class PlayerManager: VideoPlaybackTarget {
    
    public static let shared = PlayerManager()
    
    private let pool: PlayerPool
    
    private let orchestrator: PlaybackOrchestrator

    private let streamingPipeline: StreamingPipeline

    private let offlineDownloadController: OfflineDownloadController
    
    private let networkMonitor: NetworkConnectivityProviding
    
    private let networkRecovery: NetworkRecoveryCoordinator

    private let playbackAnalytics: PlaybackAnalytics
    
    private let environmentManager = EnvironmentManager()
    private let poolEnvironmentMonitor = PlayerPoolEnvironmentMonitor()
    private let audioSession = AudioSessionManager()
    private let mediaSessionCoordinator = MediaSessionCoordinator()
    private let bitrateController = DynamicBitrateController()
    private let livePlaybackSpeedController = LivePlaybackSpeedController()
    private var audioSessionObserversInstalled = false
    private var mediaSessionCommandsInstalled = false
    private var mediaSessionStateTask: Task<Void, Never>?
    private var mediaSessionProgressTask: Task<Void, Never>?
    private var mediaSessionGeneration: UInt64 = 0
    private var mediaSessionPlaybackState: PlayerState = .idle
    private var audioInterruptionActive = false
    private var isPictureInPictureActive = false
    private var pendingAudioInterruption: PendingAudioInterruption?

    private struct PendingAudioInterruption {
        let mediaId: String
    }
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
    
    public init(
        analyticsClient: any AnalyticsClient = FirebaseAnalyticsClient(),
        metricsClient: any MetricsClient = FirebasePerformanceMetricsClient()
    ) {
        
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
        
        // Share CDN health state between playback range requests and cache warming.
        let cdns = Cdn.estatiaDefaults
        let cdnSelector = CdnSelector(cdns: cdns)
        let cdnFetcher = CdnFailoverMediaDataFetcher(
            baseFetcher: URLSessionMediaDataFetcher(),
            selector: cdnSelector
        )

        let offlineDownloadController = OfflineDownloadController.shared

        let cacheConfiguration =
            PlayerCacheConfiguration(
                store:
                    cacheStore,
                fetcher:
                    cdnFetcher,
                offlineResolver:
                    offlineDownloadController
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
                    cacheStore,
                fetcher:
                    cdnFetcher
            )

        let streamingPipeline =
            DefaultStreamingPipeline(
                cdns:
                    cdns,
                cacheWarmer:
                    cacheWarmer,
                offlineController:
                    offlineDownloadController,
                cdnSelector:
                    cdnSelector
            )
        
        let orchestrator =
            PlaybackOrchestrator(
                pool: pool,
                streamingPipeline: streamingPipeline
            )
        
        let networkMonitor = NetworkConnectivityMonitor()
        
        self.playbackAnalytics = PlaybackAnalytics(
            analyticsClient: analyticsClient,
            metricsClient: metricsClient
        )
        self.pool = pool
        self.orchestrator = orchestrator
        self.streamingPipeline = streamingPipeline
        self.offlineDownloadController = offlineDownloadController
        self.networkMonitor = networkMonitor
        self.networkRecovery = NetworkRecoveryCoordinator(
            network: networkMonitor,
            playback: orchestrator
        )
    }
    
    /// Called by the presentation layer when AVKit starts or stops PiP.
    /// A background transition may retain playback only while this flag and
    /// the engine's observed playing state are both true.
    public func setPictureInPictureActive(_ isActive: Bool) {
        isPictureInPictureActive = isActive

#if canImport(UIKit)
        // Closing PiP while the app is still backgrounded ends the user's
        // explicit request to keep video running. When PiP stops because the
        // app is returning to the foreground, retain normal inline playback.
        if !isActive,
           UIApplication.shared.applicationState == .background,
           activeMediaId != nil {
            Task { @MainActor [weak self] in
                await self?.pause()
            }
        }
#endif
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
        installSystemPlaybackIntegrationIfNeeded()

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
        onPlaybackReady: @escaping @MainActor @Sendable (String, (any PlayerEngine)?) async -> Void = { _, _ in }
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

    public func playWithEngineReady(
        mediaId: String,
        source: MediaSource,
        onEngineReady: @escaping @MainActor @Sendable ((any PlayerEngine)?) async -> Void
    ) async throws {
        try await play(
            mediaId: mediaId,
            source: source,
            title: nil,
            artist: nil,
            onEngineReady: onEngineReady
        )
    }

    public func playWithEngineReady(
        mediaId: String,
        source: MediaSource,
        matchScore: Double,
        onEngineReady: @escaping @MainActor @Sendable ((any PlayerEngine)?) async -> Void
    ) async throws {
        try await play(
            mediaId: mediaId,
            source: source,
            title: nil,
            artist: nil,
            matchScore: matchScore,
            onEngineReady: onEngineReady
        )
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
        contentType: PlaybackContentType = .onDemand,
        matchScore: Double = 0.5,
        onEngineReady: (@MainActor @Sendable (any PlayerEngine) async -> Void)? = nil
    ) async throws {
        
        // Capture a monotonic request timestamp before player acquisition and
        // media preparation so startup latency includes the complete path.
        let analyticsSessionStartedAt = ProcessInfo.processInfo.systemUptime
        playbackAnalytics.finishSession(at: analyticsSessionStartedAt)

        // A new explicit play request supersedes pending lifecycle intent.
        let lifecycleGeneration = lifecycleState.invalidateForExplicitCommand()
        installSystemPlaybackIntegrationIfNeeded()
        audioSession.request()

        do {
            let qualityPreferences = PlaybackQualityPolicy().preferences(
                matchScore: matchScore,
                thermalState: poolEnvironment.thermalState
            )
            try await orchestrator.playWithEngineReady(
            mediaId: mediaId,
            source: source,
            qualityPreferences: qualityPreferences,
            onEngineReady: { [weak self] engine in
                self?.playbackAnalytics.beginSession(
                    mediaId: mediaId,
                    startedAt: analyticsSessionStartedAt
                )
                // Publish manager ownership alongside orchestrator ownership so
                // lifecycle transitions can see playback even while cache warm
                // continues in the background of this call.
                self?.activeMediaId = mediaId
                self?.activeContentType = contentType
                await self?.startMediaSessionObservation(
                    mediaId: mediaId,
                    title: title,
                    artist: artist
                )
                if let engine {
                    await onEngineReady?(engine)
                }
            }
            )
        } catch {
            playbackAnalytics.recordFailure(
                PlayerError.from(error),
                mediaId: mediaId
            )
            if lifecycleState.isCurrent(lifecycleGeneration) {
                audioSession.abandon()
            }
            throw error
        }

        guard lifecycleState.isCurrent(lifecycleGeneration) else {
            throw CancellationError()
        }

        activeMediaId = orchestrator.activeMediaId
        guard activeMediaId == mediaId else { return }
        activeContentType = contentType

        if audioInterruptionActive {
            await suspendNewPlaybackDuringAudioInterruption(
                mediaId: mediaId,
                lifecycleGeneration: lifecycleGeneration
            )
        }

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

        // PiP is the one supported video-playback exception to the normal
        // background pause policy. Keep the current AVPlayer and audio session
        // alive only if playback was already active when the app backgrounded.
        guard !BackgroundPlaybackPolicy.shouldKeepPlaybackActive(
            wasPlaying: wasPlaying,
            isPictureInPictureActive: isPictureInPictureActive
        ) else {
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

        // PiP playback never stopped in the background, so foregrounding must
        // not enqueue a redundant play command against the same managed engine.
        if isPictureInPictureActive {
            lifecycleState.finishForegroundResume(generation: transition.generation)
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

        stopBitrateMonitoring()
        await orchestrator.pauseCurrent()

        // A newer play, pause, or foreground transition may have claimed the
        // audio session while the transport pause was suspended.
        guard lifecycleState.isCurrent(lifecycleGeneration) else { return }
        audioSession.abandon()
    }
    
    /// Starts a persistent offline download for a progressive file or HLS package.
    public func handleBackgroundSessionEvents(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        offlineDownloadController.handleBackgroundSessionEvents(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }

    public func downloadOffline(mediaId: String, source: MediaSource) async throws {
        try await streamingPipeline.downloadOffline(mediaId: mediaId, source: source)
    }

    public func cancelOfflineDownload(mediaId: String) {
        streamingPipeline.cancelOfflineDownload(mediaId: mediaId)
    }

    public func removeOfflineDownload(mediaId: String) {
        streamingPipeline.removeOfflineDownload(mediaId: mediaId)
    }

    public func observeOfflineDownloads() -> AsyncStream<[OfflineDownloadRecord]> {
        streamingPipeline.observeOfflineDownloads()
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

    private func installSystemPlaybackIntegrationIfNeeded() {
        if !mediaSessionCommandsInstalled {
            mediaSessionCoordinator.installCommands(
                onPlay: { [weak self] in
                    guard let self, let mediaId = self.activeMediaId else {
                        return .unavailable
                    }
                    Task { @MainActor [weak self] in
                        await self?.resumeFromRemoteCommand(mediaId: mediaId)
                    }
                    return .success
                },
                onPause: { [weak self] in
                    guard let self, self.activeMediaId != nil else {
                        return .unavailable
                    }
                    Task { @MainActor [weak self] in
                        await self?.pause()
                    }
                    return .success
                },
                onTogglePlayback: { [weak self] in
                    guard let self, let mediaId = self.activeMediaId else {
                        return .unavailable
                    }
                    Task { @MainActor [weak self] in
                        await self?.toggleFromRemoteCommand(mediaId: mediaId)
                    }
                    return .success
                },
                onSeek: { [weak self] seconds in
                    guard let self,
                          self.activeMediaId != nil,
                          seconds.isFinite,
                          seconds >= 0
                    else {
                        return .unavailable
                    }
                    Task { @MainActor [weak self] in
                        await self?.seekFromRemoteCommand(to: seconds)
                    }
                    return .success
                }
            )
            mediaSessionCommandsInstalled = true
        }

        guard !audioSessionObserversInstalled else { return }
        audioSession.startObserving(
            onInterruptionBegan: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.handleAudioInterruptionBegan()
                }
            },
            onInterruptionEnded: { [weak self] shouldResume in
                Task { @MainActor [weak self] in
                    await self?.handleAudioInterruptionEnded(
                        shouldResume: shouldResume
                    )
                }
            },
            onRouteBecameNoisy: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.pause()
                }
            }
        )
        audioSessionObserversInstalled = true
    }

    private func resumeFromRemoteCommand(mediaId: String) async {
        guard activeMediaId == mediaId else { return }
        let generation = lifecycleState.invalidateForExplicitCommand()

        do {
            try await orchestrator.resumeCurrent()
            guard lifecycleState.isCurrent(generation),
                  activeMediaId == mediaId
            else {
                return
            }

            if audioInterruptionActive {
                // PlayerActor records the explicit play intent but keeps its
                // transport suspended until the system interruption ends.
                return
            }

            audioSession.request()
            await startBitrateMonitoring(
                mediaId: mediaId,
                contentType: activeContentType,
                lifecycleGeneration: generation
            )
        } catch {
            guard lifecycleState.isCurrent(generation),
                  activeMediaId == mediaId
            else {
                return
            }
            audioSession.abandon()
        }
    }

    private func toggleFromRemoteCommand(mediaId: String) async {
        guard activeMediaId == mediaId,
              let state = await orchestrator.currentState(mediaId: mediaId),
              activeMediaId == mediaId
        else {
            return
        }

        switch state {
        case .playing, .buffering, .reconnecting:
            await pause()
        default:
            await resumeFromRemoteCommand(mediaId: mediaId)
        }
    }

    private func seekFromRemoteCommand(to seconds: TimeInterval) async {
        guard let mediaId = activeMediaId else { return }
        do {
            try await orchestrator.seekCurrent(to: seconds)
            guard activeMediaId == mediaId,
                  let engine = await orchestrator.playerEngine(for: mediaId),
                  activeMediaId == mediaId
            else {
                return
            }
            let state = await engine.currentState
            mediaSessionCoordinator.updatePlayback(
                state: state,
                currentTime: await engine.currentTime,
                duration: await engine.duration
            )
        } catch {
            NSLog("[PlayerManager] Remote seek failed: %@", String(describing: error))
        }
    }

    private func handleAudioInterruptionBegan() async {
        guard !audioInterruptionActive else { return }
        audioInterruptionActive = true

        guard let mediaId = activeMediaId else {
            pendingAudioInterruption = nil
            return
        }

        guard activeMediaId == mediaId else { return }

        pendingAudioInterruption = PendingAudioInterruption(mediaId: mediaId)
        stopBitrateMonitoring()
        await orchestrator.pauseForAudioInterruption(mediaId: mediaId)
    }

    private func suspendNewPlaybackDuringAudioInterruption(
        mediaId: String,
        lifecycleGeneration: UInt64
    ) async {
        guard lifecycleState.isCurrent(lifecycleGeneration),
              activeMediaId == mediaId,
              audioInterruptionActive
        else {
            return
        }

        pendingAudioInterruption = PendingAudioInterruption(mediaId: mediaId)
        await orchestrator.pauseForAudioInterruption(mediaId: mediaId)
    }

    private func handleAudioInterruptionEnded(shouldResume systemAllowsResume: Bool) async {
        guard audioInterruptionActive else { return }
        audioInterruptionActive = false

        guard let interruption = pendingAudioInterruption else { return }
        pendingAudioInterruption = nil

        guard activeMediaId == interruption.mediaId else { return }

        // PlayerActor keeps desired playback separate from observed transport
        // state. Reading it here respects user play/pause commands issued
        // directly by the player UI while the system owned audio.
        let currentIntent = await orchestrator.shouldResumeAfterInterruption(
            mediaId: interruption.mediaId
        )
        guard activeMediaId == interruption.mediaId else { return }

        // PlayerEngine preserves desired playback intent while interrupted.
        // A pause issued directly by the player UI must cancel auto-resume.
        let shouldResume = systemAllowsResume && currentIntent

        do {
            // AVAudioSession must be active before the engine resumes its
            // transport, otherwise the first playback command can be dropped.
            if shouldResume {
                audioSession.request()
            }

            try await orchestrator.resumeFromAudioInterruption(
                mediaId: interruption.mediaId,
                shouldResume: shouldResume
            )
            guard activeMediaId == interruption.mediaId else { return }

            if shouldResume {
                let generation = lifecycleState.generation
                await startBitrateMonitoring(
                    mediaId: interruption.mediaId,
                    contentType: activeContentType,
                    lifecycleGeneration: generation
                )
            } else {
                audioSession.abandon()
            }
        } catch {
            audioSession.abandon()
            NSLog("[PlayerManager] Audio-interruption recovery failed: %@", String(describing: error))
        }
    }

    private func stopBitrateMonitoring() {
        bitrateMonitoringGeneration &+= 1
        bitrateTask?.cancel()
        bitrateTask = nil
        if let monitoredBitrateEngine {
            bitrateController.reset(for: monitoredBitrateEngine)
            livePlaybackSpeedController.reset(for: monitoredBitrateEngine)
            monitoredBitrateEngine.setLivePlaybackEnabled(false)
            self.monitoredBitrateEngine = nil
        }
        monitoredBitrateContentType = nil
        latestBitrateProgress = nil
    }

    private func startMediaSessionObservation(
        mediaId: String,
        title: String?,
        artist: String?
    ) async {
        mediaSessionGeneration &+= 1
        let generation = mediaSessionGeneration
        mediaSessionStateTask?.cancel()
        mediaSessionProgressTask?.cancel()
        mediaSessionStateTask = nil
        mediaSessionProgressTask = nil

        guard let engine = await orchestrator.playerEngine(for: mediaId),
              activeMediaId == mediaId,
              generation == mediaSessionGeneration
        else {
            return
        }

        // Create both multicast subscriptions before taking the snapshot so
        // a transition racing with the initial read remains observable.
        let states = engine.state
        let events = engine.events
        let initialState = await engine.currentState
        let initialTime = await engine.currentTime
        let initialDuration = await engine.duration

        guard activeMediaId == mediaId,
              generation == mediaSessionGeneration
        else {
            return
        }

        mediaSessionPlaybackState = initialState
        playbackAnalytics.observe(state: initialState)
        mediaSessionCoordinator.activate(
            title: title,
            artist: artist,
            state: initialState,
            currentTime: initialTime,
            duration: initialDuration
        )

        mediaSessionStateTask = Task { @MainActor [weak self, engine] in
            for await state in states {
                guard !Task.isCancelled,
                      let self,
                      self.mediaSessionGeneration == generation,
                      self.activeMediaId == mediaId
                else {
                    return
                }

                self.mediaSessionPlaybackState = state
                self.playbackAnalytics.observe(state: state)
                let currentTime = await engine.currentTime
                let duration = await engine.duration
                guard self.mediaSessionGeneration == generation,
                      self.activeMediaId == mediaId
                else {
                    return
                }
                self.mediaSessionCoordinator.updatePlayback(
                    state: state,
                    currentTime: currentTime,
                    duration: duration
                )
            }
        }

        mediaSessionProgressTask = Task { @MainActor [weak self] in
            for await event in events {
                guard !Task.isCancelled,
                      let self,
                      self.mediaSessionGeneration == generation,
                      self.activeMediaId == mediaId
                else {
                    return
                }

                self.playbackAnalytics.observe(event: event)
                guard case let .progress(progress) = event else { continue }
                self.mediaSessionCoordinator.updateProgress(
                    currentTime: progress.currentTime,
                    duration: progress.duration
                )
            }
        }
    }

    private func stopMediaSessionObservation() {
        playbackAnalytics.finishSession()
        mediaSessionGeneration &+= 1
        mediaSessionStateTask?.cancel()
        mediaSessionProgressTask?.cancel()
        mediaSessionStateTask = nil
        mediaSessionProgressTask = nil
        mediaSessionPlaybackState = .idle
        mediaSessionCoordinator.clear()
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
            livePlaybackSpeedController.reset(for: previousEngine)
            previousEngine.setLivePlaybackEnabled(false)
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
        provider.setLivePlaybackEnabled(contentType == .live)
        if contentType != .live {
            livePlaybackSpeedController.reset(for: provider)
        }

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
            isStartup: progress.currentTime < 5,
            deviceMaximumBitrateBps: environment.thermalState == .nominal
                ? nil
                : 2_000_000
        )

        bitrateController.apply(input, to: provider)

        if contentType == .live {
            livePlaybackSpeedController.apply(
                provider.livePlaybackTiming,
                to: provider
            )
        } else {
            livePlaybackSpeedController.reset(for: provider)
        }
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

        stopBitrateMonitoring()
        stopMediaSessionObservation()
        pendingAudioInterruption = nil
        audioInterruptionActive = false
        isPictureInPictureActive = false
        audioSession.cleanup()
        audioSessionObserversInstalled = false
        mediaSessionCommandsInstalled = false
        
        await orchestrator.shutdown()
        
        environmentManager.stop()
        
        activeMediaId = nil
    }
}
