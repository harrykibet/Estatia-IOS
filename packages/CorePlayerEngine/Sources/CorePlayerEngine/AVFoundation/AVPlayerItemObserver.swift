//
//  AVPlayerItemObserver.swift
//  CorePlayerEngine
//
//  Responsibility:
//  - Observes AVPlayerItem KVO + notifications
//  - Emits high-level PlayerEvent signals
//  - Contains NO business logic or state ownership
//
//  Design:
//  - Stateless (except minimal lifecycle tracking)
//  - Does not dispatch threads (caller decides)
//  - Safe attach/detach lifecycle
//

import Foundation
import AVFoundation

/// Bridges AVPlayerItem observations into PlayerEvent values.
///
/// Observation-token lifecycle and event-sink access are independently
/// synchronized. AVFoundation may invoke KVO and notification handlers on
/// arbitrary queues, so this type is explicitly Sendable only because those
/// shared mutable references are protected by locks.
final class AVPlayerItemObserver: @unchecked Sendable {

    // MARK: - Event Sink

    private let eventSinkLock = NSLock()
    private var eventSink: ((PlayerEvent) -> Void)?

    var emit: ((PlayerEvent) -> Void)? {
        get {
            eventSinkLock.lock()
            defer { eventSinkLock.unlock() }
            return eventSink
        }
        set {
            eventSinkLock.lock()
            defer { eventSinkLock.unlock() }
            eventSink = newValue
        }
    }

    // MARK: - Observation Lifecycle

    private let lifecycleLock = NSLock()

    private var statusObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?

    // MARK: - Public API

    func attach(to item: AVPlayerItem) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        detachObservations()

        observeStatus(item)
        observeCompletion(item)
        observeFailure(item)
    }

    func detach() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        detachObservations()
    }

    // MARK: - Cleanup

    private func detachObservations() {
        statusObserver?.invalidate()
        statusObserver = nil

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }

        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
        }

        endObserver = nil
        failureObserver = nil
    }
}

// MARK: - Observations

private extension AVPlayerItemObserver {

    func observeStatus(_ item: AVPlayerItem) {
        statusObserver = item.observe(
            \.status,
            options: [.new, .initial]
        ) { [weak self] item, _ in
            guard let self else { return }

            switch item.status {
            case .readyToPlay:
                self.emit?(.ready)

            case .failed:
                if let error = item.error {
                    self.emit?(.failed(PlayerError.from(error)))
                } else {
                    self.emit?(.failed(.unknown))
                }

            case .unknown:
                break

            @unknown default:
                break
            }
        }
    }

    func observeCompletion(_ item: AVPlayerItem) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: nil
        ) { [weak self] _ in
            self?.emit?(.playbackCompleted)
        }
    }

    func observeFailure(_ item: AVPlayerItem) {
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: nil
        ) { [weak self] notification in
            let error = notification.userInfo?[
                AVPlayerItemFailedToPlayToEndTimeErrorKey
            ] as? Error

            self?.emit?(
                .failed(
                    error.map { PlayerError.from($0) } ?? .unknown
                )
            )
        }
    }
}
