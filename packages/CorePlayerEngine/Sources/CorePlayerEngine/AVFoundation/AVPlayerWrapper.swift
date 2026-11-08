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
        MediaCacheResourceLoader?

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

    // MARK: - Initialization

    init(
        progressInterval:
            TimeInterval,

        cacheConfiguration:
            PlayerCacheConfiguration? = nil
    ) {
        self.progressInterval =
            progressInterval

        self.cacheConfiguration =
            cacheConfiguration

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
                            source
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

        let useCache =
            cacheConfiguration != nil &&
            Self.isProgressivelyCacheable(
                source
            )

        if useCache,
           let cacheConfiguration {

            try loadCached(
                mediaId:
                    mediaId,
                source:
                    source,
                configuration:
                    cacheConfiguration
            )

        } else {

            loadDirect(
                source:
                    source
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
            MediaCacheResourceLoader?
    ) {

        self.asset =
            asset

        self.playerItem =
            item

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
                    self.onReady?()

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
