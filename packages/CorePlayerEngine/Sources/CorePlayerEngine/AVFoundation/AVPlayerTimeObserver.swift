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

/// Observes AVPlayer time on a dedicated serial queue.
///
/// AVPlayer's periodic-time callback executes on this queue. Attach, detach,
/// and event-sink access are synchronously serialized through the same queue,
/// including when callers originate outside it. This is the synchronization
/// contract behind the unchecked Sendable conformance.
final class AVPlayerTimeObserver: @unchecked Sendable {

    // MARK: - Event Sink

    private var eventSink: ((PlayerEvent) -> Void)?

    var emit: ((PlayerEvent) -> Void)? {
        get {
            onQueue { eventSink }
        }
        set {
            onQueue {
                eventSink = newValue
            }
        }
    }

    // MARK: - Private

    private weak var player: AVPlayer?
    private weak var item: AVPlayerItem?
    private var timeObserverToken: Any?

    private let interval: TimeInterval
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()

    // MARK: - Init

    /// The supplied queue must be serial so all AVPlayer observer state has
    /// a single owner. Callers may invoke attach/detach from any queue.
    init(interval: TimeInterval, queue: DispatchQueue) {
        self.interval = interval
        self.queue = queue
        queue.setSpecific(key: queueKey, value: 1)
    }

    // MARK: - Public API

    func attach(player: AVPlayer, item: AVPlayerItem) {
        onQueue {
            detachOnQueue()

            self.player = player
            self.item = item

            let cmInterval = CMTime(
                seconds: interval,
                preferredTimescale: 600
            )

            timeObserverToken = player.addPeriodicTimeObserver(
                forInterval: cmInterval,
                queue: queue
            ) { [weak self] time in
                self?.handle(time: time)
            }
        }
    }

    func detach() {
        onQueue {
            detachOnQueue()
        }
    }

    // MARK: - Queue Ownership

    private func onQueue<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) == 1 {
            return operation()
        }

        return queue.sync(execute: operation)
    }

    private func detachOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))

        if let token = timeObserverToken, let player {
            player.removeTimeObserver(token)
        }

        timeObserverToken = nil
        player = nil
        item = nil
    }

    // MARK: - Progress

    private func handle(time: CMTime) {
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

        eventSink?(.progress(progress))
    }
}
