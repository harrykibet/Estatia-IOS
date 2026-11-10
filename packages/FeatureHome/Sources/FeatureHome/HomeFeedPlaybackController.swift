import Foundation
import SwiftUI

import CoreModel
import CorePlayerEngine

@MainActor
public final class HomeFeedPlaybackController: ObservableObject {
    @Published public private(set) var engines: [String: any PlayerEngine] = [:]
    @Published public private(set) var selectedMediaID: String?
    @Published public private(set) var isMuted = true

    private let playerManager: PlayerManager
    private var composedMediaIDs = Set<String>()
    private var compositionUpdateTask: Task<Void, Never>?
    private var isStopped = true

    private lazy var coordinator: VideoPlaybackCoordinator = {
        playerManager.makeFeedPlaybackCoordinator(
            onPlaybackReady: { [weak self] mediaId, engine in
                guard let self,
                      let engine,
                      !self.isStopped,
                      self.selectedMediaID == mediaId,
                      self.composedMediaIDs.contains(mediaId),
                      self.playerManager.isMediaActive(mediaId)
                else {
                    return
                }

                self.engines[mediaId] = engine
            }
        )
    }()

    public init(playerManager: PlayerManager = .shared) {
        self.playerManager = playerManager
    }

    public func start() {
        isStopped = false
        playerManager.start()
    }

    public func toggleMute() {
        isMuted.toggle()
    }

    /// Tracks media whose feed cells are currently composed. Pinning these IDs
    /// prevents the shared pool from recycling their engine while SwiftUI still
    /// holds a player view for the corresponding cell.
    public func setComposed(_ isComposed: Bool, property: PropertyModel) {
        guard !isStopped,
              let item = makeFeedPlaybackItem(from: property)
        else {
            return
        }

        if isComposed {
            composedMediaIDs.insert(item.mediaId)
        } else {
            composedMediaIDs.remove(item.mediaId)
            engines.removeValue(forKey: item.mediaId)
        }

        let snapshot = composedMediaIDs
        let previousUpdate = compositionUpdateTask
        compositionUpdateTask = Task { @MainActor [weak self] in
            await previousUpdate?.value
            guard let self, !self.isStopped else { return }
            await self.coordinator.updateComposedMedia(snapshot)
        }
    }

    /// Selects the most visible property and supplies its nearest video
    /// neighbors to the engine coordinator for preloading.
    public func itemBecameVisible(in properties: [PropertyModel], at index: Int) {
        guard !isStopped,
              properties.indices.contains(index)
        else {
            return
        }

        guard let current = makeFeedPlaybackItem(from: properties[index]) else {
            selectedMediaID = nil
            Task { await coordinator.pause() }
            return
        }

        selectedMediaID = current.mediaId

        let previous = Array(
            properties[..<index]
                .reversed()
                .compactMap { makeFeedPlaybackItem(from: $0) }
                .prefix(1)
        )
        let next = Array(
            properties.dropFirst(index + 1)
                .compactMap { makeFeedPlaybackItem(from: $0) }
                .prefix(2)
        )

        coordinator.onItemVisible(
            current,
            previous: previous,
            next: next
        )
    }

    public func stop() async {
        isStopped = true
        selectedMediaID = nil

        await coordinator.pause()
        coordinator.clear()

        if let compositionUpdateTask {
            await compositionUpdateTask.value
        }

        composedMediaIDs.removeAll()
        engines.removeAll()
        await coordinator.updateComposedMedia([])
    }
}

/// Converts a property model to the player engine's feed contract. A property
/// remains a valid feed cell without video; only absolute HTTP(S) URLs are
/// eligible for autoplay.
func makeFeedPlaybackItem(from property: PropertyModel) -> FeedPlaybackItem? {
    guard let mediaId = property.id?.trimmingCharacters(in: .whitespacesAndNewlines),
          !mediaId.isEmpty
    else {
        return nil
    }

    let sourceURL = property.videoUrl.lazy.compactMap { value -> URL? in
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil
        else {
            return nil
        }
        return url
    }.first

    guard let sourceURL else {
        return nil
    }

    return FeedPlaybackItem(
        mediaId: mediaId,
        source: MediaSource(url: sourceURL, type: .auto),
        matchScore: 0.5,
        title: property.title,
        artist: property.ownerName
    )
}
