//
//  AVPlayerWrapper.swift
//  CorePlayerEngine
//
//  Created by builder on 9/24/26.
//


//
//  AVPlayerWrapper.swift
//  CorePlayerEngine
//

import AVFoundation
import Foundation

@available(iOS 18.0, macOS 10.15, *)
final class AVPlayerWrapper:
    PlayerTransport,
    @unchecked Sendable {

    // MARK: - Callbacks

    var onReady:
        (@MainActor @Sendable () -> Void)?

    var onCompletion:
        (@MainActor @Sendable () -> Void)?

    var onError:
        (@MainActor @Sendable (Error) -> Void)?

    var onProgress:
        (@MainActor @Sendable (PlaybackProgress) -> Void)?

    var onTransportStatus:
        (@Sendable (PlayerTransportStatus) -> Void)?

    // MARK: - AVFoundation

    private var player:
        AVPlayer?

    private var playerItem:
        AVPlayerItem?

    private var asset:
        AVURLAsset?

    // MARK: - Resource Loader

    private var resourceLoader:
        (any AVAssetResourceLoaderDelegate)?

    private var timeControlObserver:
        NSKeyValueObservation?

    // Accessed by AVFoundation callbacks and the player queue.
    private let sessionGenerationLock = NSLock()
    private var sessionGeneration: UInt64 = 0

    private let resourceLoaderQueue =
        DispatchQueue(
            label:
                "com.estatia.coreplayerengine.resource-loader",
            qos:
                .userInitiated
        )

    // MARK: - Observers

    private let itemObserver =
        AVPlayerItemObserver()

    private let timeObserver:
        AVPlayerTimeObserver

    // MARK: - Player Queue

    private let queue =
        DispatchQueue(
            label:
                "com.estatia.coreplayerengine.player-wrapper",
            qos:
                .userInitiated
        )

    // MARK: - Configuration

    private let progressInterval:
        TimeInterval

    private let cacheConfiguration:
        PlayerCacheConfiguration?

    private let codecNegotiator:
        StreamingCodecNegotiator

    // These values are confined to the serial player queue.
    private var playbackQualityPreferences = PlaybackQualityPreferences.unrestricted
    private var isCurrentAssetHLS = false
    private var isLivePlaybackEnabled = false
    private var initialPlaybackPosition: TimeInterval?

    // MARK: - Initialization

    init(
        progressInterval:
            TimeInterval,

        cacheConfiguration:
            PlayerCacheConfiguration? = nil,

        codecNegotiator:
            StreamingCodecNegotiator = StreamingCodecNegotiator()
    ) {
        self.progressInterval =
            progressInterval

        self.cacheConfiguration =
            cacheConfiguration

        self.codecNegotiator =
            codecNegotiator

        self.timeObserver =
            AVPlayerTimeObserver(
                interval:
                    progressInterval,
                queue:
                    queue
            )
    }

    deinit {

        queue.sync {
            cleanup()
        }
    }

    // MARK: - Load

    nonisolated(nonsending)
    func load(
        mediaId:
            String,
        source:
            MediaSource
    ) async throws {

        // Prefer a completed local artifact when the original logical source
        // matches the persisted offline-download record. Network playback and
        // the media identity remain unchanged when no such artifact exists.
        let playbackSource: MediaSource
        if let resolver = cacheConfiguration?.offlineResolver,
           let offlineSource = await resolver.offlineSource(
                for: mediaId,
                originalSource: source
           ) {
            playbackSource = offlineSource
        } else {
            playbackSource = source
        }

        try await withCheckedThrowingContinuation {
            (
                continuation:
                    CheckedContinuation<
                        Void,
                        Error
                    >
            ) in

            queue.async { [weak self] in

                guard let self else {

                    continuation.resume(
                        throwing:
                            PlayerError.unknown
                    )

                    return
                }

                do {

                    try self.loadSynchronously(
                        mediaId:
                            mediaId,
                        source:
                            playbackSource
                    )

                    continuation.resume()

                } catch {

                    continuation.resume(
                        throwing:
                            error
                    )
                }
            }
        }
    }

    private func loadSynchronously(
        mediaId:
            String,
        source:
            MediaSource
    ) throws {

        cleanup()

        // Resolve the same codec-aware source before either playback or
        // cache loading so the manifest variant and cache identity agree.
        let negotiatedSource = codecNegotiator.negotiate(source)
        isCurrentAssetHLS = negotiatedSource.type == .hls
            || negotiatedSource.url.pathExtension.lowercased() == "m3u8"

        let useCache =
            cacheConfiguration != nil &&
            Self.isProgressivelyCacheable(
                negotiatedSource
            )

        if useCache,
           let cacheConfiguration {

            try loadCached(
                mediaId:
                    mediaId,
                source:
                    negotiatedSource,
                configuration:
                    cacheConfiguration
            )

        } else if HLSResourceLoader.supports(negotiatedSource) {

            // HLS master/media playlists and their child resources are routed
            // through this asset's resource loader, preserving the same player.
            try loadHLS(
                source:
                    negotiatedSource,
                fetcher:
                    cacheConfiguration?.fetcher ?? URLSessionMediaDataFetcher()
            )

        } else {

            loadDirect(
                source:
                    negotiatedSource
            )
        }
    }

    // MARK: - Cached Load

    private func loadCached(
        mediaId:
            String,
        source:
            MediaSource,
        configuration:
            PlayerCacheConfiguration
    ) throws {

        guard let cachedURL =
                MediaCacheResourceLoader.cachedURL(
                    for:
                        source.url
                )
        else {

            throw PlayerError.invalidSource
        }

        let loader =
            MediaCacheResourceLoader(
                mediaId:
                    mediaId,
                source:
                    source,
                configuration:
                    configuration
            )

        let urlAsset =
            AVURLAsset(
                url:
                    cachedURL,
                options:
                    nil
            )

        urlAsset.resourceLoader.setDelegate(
            loader,
            queue:
                resourceLoaderQueue
        )

        let item =
            AVPlayerItem(
                asset:
                    urlAsset
            )

        install(
            asset:
                urlAsset,
            item:
                item,
            resourceLoader:
                loader
        )
    }

    // MARK: - HLS Load

    private func loadHLS(
        source:
            MediaSource,
        fetcher:
            any MediaDataFetching
    ) throws {

        guard let proxiedURL =
                HLSResourceLoader.proxyURL(
                    for:
                        source.url
                )
        else {
            throw PlayerError.invalidSource
        }

        let loader =
            HLSResourceLoader(
                source:
                    source,
                fetcher:
                    fetcher
            )

        let urlAsset =
            AVURLAsset(
                url:
                    proxiedURL,
                options:
                    nil
            )

        urlAsset.resourceLoader.setDelegate(
            loader,
            queue:
                resourceLoaderQueue
        )

        let item =
            AVPlayerItem(
                asset:
                    urlAsset
            )

        install(
            asset:
                urlAsset,
            item:
                item,
            resourceLoader:
                loader
        )
    }

    // MARK: - Direct Load

    private func loadDirect(
        source:
            MediaSource
    ) {

        var options:
            [String: Any] = [:]

        if let headers =
            source.headers {

            options[
                "AVURLAssetHTTPHeaderFieldsKey"
            ] =
                headers
        }

        let urlAsset =
            AVURLAsset(
                url:
                    source.url,
                options:
                    options
            )

        let item =
            AVPlayerItem(
                asset:
                    urlAsset
            )

        install(
            asset:
                urlAsset,
            item:
                item,
            resourceLoader:
                nil
        )
    }

    // MARK: - Install

    private func install(
        asset:
            AVURLAsset,
        item:
            AVPlayerItem,
        resourceLoader:
            (any AVAssetResourceLoaderDelegate)?
    ) {

        self.asset =
            asset

        self.playerItem =
            item

        item.automaticallyPreservesTimeOffsetFromLive = isLivePlaybackEnabled
        applyPlaybackQuality(to: item)

        self.resourceLoader =
            resourceLoader

        let player = AVPlayer(playerItem: item)
        self.player = player

        // Capture the load generation so observations already queued by a
        // previous item cannot mutate the state of a newly loaded item.
        let generation = currentSessionGeneration

        // Install event sinks before attaching observers. The item observer
        // requests an initial KVO value and must not lose that first event.
        itemObserver.emit = { [weak self] event in
            guard let self,
                  self.isCurrentSession(generation)
            else {
                return
            }

            self.dispatch { [weak self] in
                guard let self,
                      self.isCurrentSession(generation)
                else {
                    return
                }

                switch event {
                case .ready:
                    self.restoreInitialPlaybackPosition {
                        guard self.isCurrentSession(generation) else { return }
                        self.onReady?()
                    }

                case .playbackCompleted:
                    self.onCompletion?()

                case .failed(let error):
                    self.onError?(error)

                default:
                    break
                }
            }
        }

        timeObserver.emit = { [weak self] event in
            guard case let .progress(progress) = event,
                  let self,
                  self.isCurrentSession(generation)
            else {
                return
            }

            self.dispatch { [weak self] in
                guard let self,
                      self.isCurrentSession(generation)
                else {
                    return
                }

                self.onProgress?(progress)
            }
        }

        timeControlObserver = player.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { [weak self] observedPlayer, _ in
            let status = Self.transportStatus(
                from: observedPlayer.timeControlStatus
            )

            guard let self,
                  self.isCurrentSession(generation)
            else {
                return
            }

            self.onTransportStatus?(status)
        }

        itemObserver.attach(to: item)
        timeObserver.attach(player: player, item: item)
    }

    // MARK: - Presentation

    /// Returns the currently loaded AVPlayer to the main-actor presentation layer.
    /// The wrapper retains exclusive mutation of the player on its serial queue.
    @MainActor
    func presentationPlayer() -> AVPlayer? {
        queue.sync { player }
    }

    // MARK: - Bitrate

    /// Access-log reads and AVPlayerItem mutations are serialized with the
    /// wrapper's AVFoundation queue.
    @MainActor
    func observedBitrateBps() -> Double? {
        queue.sync {
            guard let event = playerItem?.accessLog()?.events.last(where: {
                $0.observedBitrate.isFinite && $0.observedBitrate > 0
            }) else {
                return nil
            }
            return event.observedBitrate
        }
    }

    /// Reads the actual transport rate from the same serial queue that owns
    /// AVPlayer mutations. This detects rate resets that occur without a
    /// corresponding command from LivePlaybackSpeedController.
    @MainActor
    func currentPlaybackRate() -> Float? {
        queue.sync {
            player?.rate
        }
    }

    /// Reads the current media time from the serialized AVPlayer queue.
    /// Nil means the item is not yet ready or its time is invalid.
    @MainActor
    func currentPlaybackPosition() -> TimeInterval? {
        queue.sync {
            guard let player,
                  let item = playerItem,
                  item.status == .readyToPlay
            else {
                return nil
            }

            let seconds = player.currentTime().seconds
            guard seconds.isFinite, seconds >= 0 else {
                return nil
            }
            return seconds
        }
    }

    /// Sets or clears the one-shot position for the next loaded item.
    @MainActor
    func setInitialPlaybackPosition(_ seconds: TimeInterval?) {
        let safePosition = seconds.flatMap { value in
            value.isFinite && value >= 0 ? value : nil
        }
        queue.async { [weak self] in
            self?.initialPlaybackPosition = safePosition
        }
    }

    /// Waits for an initial seek before signalling item readiness to PlayerActor.
    @MainActor
    private func restoreInitialPlaybackPosition(
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        queue.async { [weak self] in
            guard let self,
                  let seconds = self.initialPlaybackPosition,
                  let player = self.player
            else {
                Task { @MainActor in completion() }
                return
            }

            self.initialPlaybackPosition = nil
            let target = CMTime(
                seconds: seconds,
                preferredTimescale: 600
            )
            player.seek(
                to: target,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { _ in
                Task { @MainActor in completion() }
            }
        }
    }

    @MainActor
    func setPreferredPeakBitRate(_ bitrateBps: Double) {
        let safeBitrate = bitrateBps.isFinite ? max(0, bitrateBps) : 0
        queue.async { [weak self] in
            self?.playerItem?.preferredPeakBitRate = safeBitrate
        }
    }

    /// Reads the current distance from the end of the seekable window and
    /// AVFoundation's recommended target for the active live item.
    @MainActor
    func livePlaybackTimingSnapshot() -> LivePlaybackTiming? {
        queue.sync {
            guard let player,
                  let item = playerItem,
                  player.timeControlStatus == .playing
            else {
                return nil
            }

            let currentTime = player.currentTime().seconds
            let recommendedOffset = item.recommendedTimeOffsetFromLive.seconds
            let seekableEnd = item.seekableTimeRanges
                .compactMap { value -> Double? in
                    let end = CMTimeRangeGetEnd(value.timeRangeValue).seconds
                    return end.isFinite ? end : nil
                }
                .max()

            guard let seekableEnd,
                  currentTime.isFinite,
                  recommendedOffset.isFinite,
                  recommendedOffset >= 0,
                  seekableEnd >= currentTime
            else {
                return nil
            }

            return LivePlaybackTiming(
                currentOffsetSeconds: seekableEnd - currentTime,
                recommendedOffsetSeconds: recommendedOffset
            )
        }
    }

    /// Turns on AVFoundation's offset-preservation behavior for live items.
    /// It has no effect for VOD items.
    @MainActor
    func setLivePlaybackEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.isLivePlaybackEnabled = enabled
            self.playerItem?.automaticallyPreservesTimeOffsetFromLive = enabled

            if !enabled,
               let player = self.player,
               player.timeControlStatus == .playing,
               player.rate > 0 {
                player.rate = 1.0
            }
        }
    }

    /// Adjusts only an already-playing transport; it never starts a paused or
    /// waiting player and therefore cannot override PlayerActor's play intent.
    @MainActor
    func setLivePlaybackSpeed(_ speed: Float) {
        guard speed.isFinite, speed > 0 else { return }

        queue.async { [weak self] in
            guard let player = self?.player,
                  player.timeControlStatus == .playing,
                  player.rate > 0
            else {
                return
            }

            player.rate = speed
        }
    }

    /// Queues rendition constraints before the corresponding play command.
    @MainActor
    func setPlaybackQuality(_ preferences: PlaybackQualityPreferences) {
        queue.async { [weak self] in
            guard let self else { return }
            self.playbackQualityPreferences = preferences
            if let item = self.playerItem {
                self.applyPlaybackQuality(to: item)
            }
        }
    }

    /// AVPlayer performs HLS adaptation within these preferences; it does not
    /// force one fixed variant. Resolution preferences are HLS-only.
    private func applyPlaybackQuality(to item: AVPlayerItem) {
        if isCurrentAssetHLS,
           let resolution = playbackQualityPreferences.maximumResolution {
            item.preferredMaximumResolution = CGSize(
                width: CGFloat(resolution.width),
                height: CGFloat(resolution.height)
            )
        } else {
            item.preferredMaximumResolution = .zero
        }

        item.preferredPeakBitRate =
            playbackQualityPreferences.maximumPeakBitrateBps ?? 0
    }

    // MARK: - Playback

    func play() {

        queue.async { [weak self] in
            self?.player?.play()
        }
    }

    func pause() {

        queue.async { [weak self] in
            self?.player?.pause()
        }
    }

    func stop() {

        queue.async { [weak self] in

            self?.player?.pause()

            self?.player?.seek(
                to:
                    .zero
            )
        }
    }

    // MARK: - Seek

    nonisolated(nonsending)
    func seek(
        to seconds:
            TimeInterval
    ) async throws {

        try await withCheckedThrowingContinuation {
            (
                continuation:
                    CheckedContinuation<
                        Void,
                        Error
                    >
            ) in

            queue.async { [weak self] in

                guard
                    let self,
                    let player =
                        self.player
                else {

                    continuation.resume(
                        throwing:
                            PlayerError.seekFailed
                    )

                    return
                }

                let time =
                    CMTime(
                        seconds:
                            seconds,
                        preferredTimescale:
                            600
                    )

                player.seek(
                    to:
                        time,
                    toleranceBefore:
                        .zero,
                    toleranceAfter:
                        .zero
                ) { finished in

                    if finished {

                        continuation.resume()

                    } else {

                        continuation.resume(
                            throwing:
                                PlayerError.seekFailed
                        )
                    }
                }
            }
        }
    }

    // MARK: - Release

    func release() {

        queue.sync {
            cleanup()
        }
    }

    // MARK: - Cleanup

    private func cleanup() {

        advanceSessionGeneration()
        timeControlObserver?.invalidate()
        timeControlObserver = nil

        resourceLoader = nil

        // Break observer-to-wrapper callbacks before detaching AVFoundation
        // observations so a queued callback cannot retain stale event sinks.
        itemObserver.emit = nil
        timeObserver.emit = nil

        itemObserver.detach()
        timeObserver.detach()

        player?.pause()

        player?.replaceCurrentItem(
            with:
                nil
        )

        player =
            nil

        playerItem =
            nil

        asset =
            nil
        isCurrentAssetHLS = false
    }

    // MARK: - Session Generation

    private var currentSessionGeneration: UInt64 {
        sessionGenerationLock.lock()
        defer { sessionGenerationLock.unlock() }
        return sessionGeneration
    }

    private func advanceSessionGeneration() {
        sessionGenerationLock.lock()
        sessionGeneration &+= 1
        sessionGenerationLock.unlock()
    }

    private func isCurrentSession(_ generation: UInt64) -> Bool {
        currentSessionGeneration == generation
    }

    private static func transportStatus(
        from status: AVPlayer.TimeControlStatus
    ) -> PlayerTransportStatus {
        switch status {
        case .paused:
            return .paused

        case .waitingToPlayAtSpecifiedRate:
            return .waiting

        case .playing:
            return .playing

        @unknown default:
            return .paused
        }
    }

    // MARK: - Dispatch

    private func dispatch(
        _ block:
            @MainActor
            @Sendable
            @escaping () -> Void
    ) {

        Task { @MainActor in
            block()
        }
    }

    // MARK: - Cacheability

    private static func
        isProgressivelyCacheable(
            _ source:
                MediaSource
        ) -> Bool {

        switch source.type {

        case .progressive:
            return true

        case .hls,
             .dash,
             .file:
            return false

        case .auto:

            let extensionName =
                source.url
                    .pathExtension
                    .lowercased()

            return extensionName != "m3u8" &&
                   extensionName != "mpd"
        }
    }

}
