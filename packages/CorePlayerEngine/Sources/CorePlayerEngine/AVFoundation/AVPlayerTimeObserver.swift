//
//  AVPlayerTimeObserver.swift
//  CorePlayerEngine
//
//  Responsibility:
//  - Emits playback progress at a fixed interval
//  - Does NOT own playback state
//  - Does NOT perform UI dispatching
//
//  Design:
//  - Lightweight, high-frequency safe
//  - Emits PlayerEvent.progress
//

import Foundation
import AVFoundation

/// Observes AVPlayer time on the serial queue supplied at initialization.
///
/// All mutable state (including attach/detach and the periodic-time callback)
/// is confined to that queue. The unchecked conformance communicates this
/// queue-serialization contract to Swift 6's Sendable checking.
final class AVPlayerTimeObserver: @unchecked Sendable {

    // MARK: - Event Sink

    var emit: ((PlayerEvent) -> Void)?

    // MARK: - Private

    private weak var player: AVPlayer?
    private weak var item: AVPlayerItem?

    private var timeObserverToken: Any?

    private let interval: TimeInterval
    private let queue: DispatchQueue

    // MARK: - Init

    init(interval: TimeInterval, queue: DispatchQueue) {
        self.interval = interval
        self.queue = queue
    }

    // MARK: - Public API

    func attach(player: AVPlayer, item: AVPlayerItem) {
        dispatchPrecondition(condition: .onQueue(queue))
        detach()

        self.player = player
        self.item = item

        let cmInterval = CMTime(seconds: interval, preferredTimescale: 600)

        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: cmInterval,
            queue: queue
        ) { [weak self] time in
            self?.handle(time: time)
        }
    }

    func detach() {
        dispatchPrecondition(condition: .onQueue(queue))

        if let token = timeObserverToken, let player {
            player.removeTimeObserver(token)
        }

        timeObserverToken = nil
        player = nil
        item = nil
    }
}

// MARK: - Internal

private extension AVPlayerTimeObserver {

    func handle(time: CMTime) {
        dispatchPrecondition(condition: .onQueue(queue))

        guard let item else { return }

        let current = time.seconds

        let duration = item.duration.seconds.isFinite
            ? item.duration.seconds
            : nil

        let buffered = item.loadedTimeRanges
            .compactMap { $0.timeRangeValue }
            .map { $0.start.seconds + $0.duration.seconds }
            .max()

        let progress = PlaybackProgress(
            currentTime: current,
            duration: duration,
            buffered: buffered
        )

        emit?(.progress(progress))
    }
}
