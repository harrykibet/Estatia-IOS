import Foundation
import SwiftUI

import CoreAppData
import CoreModel
import CorePlayerEngine

@MainActor
public final class HomeViewModel: ObservableObject {
    @Published public private(set) var properties: [PropertyModel] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var loadError: String?
    @Published public private(set) var isMuted = true

    private let repository: PropertyRepository
    private let playerManager: PlayerManager
    private let playbackCoordinator: VideoPlaybackCoordinator
    private var composedMediaIDs: Set<String> = []

    public init(
        repository: PropertyRepository,
        playerManager: PlayerManager = .shared
    ) {
        self.repository = repository
        self.playerManager = playerManager
        self.playbackCoordinator = playerManager.makeFeedPlaybackCoordinator()
        playerManager.start()
    }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            properties = try await repository.fetchProperties()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Converts the backend property contract into the engine's stable feed
    /// identity. Invalid or absent URLs are deliberately excluded from autoplay.
    public static func playbackItem(for property: PropertyModel) -> FeedPlaybackItem? {
        guard let mediaID = property.id, !mediaID.isEmpty else {
            return nil
        }

        // Match Android's HLS-first policy, then direct video, while retaining
        // the legacy iOS videoUrl field as a backwards-compatible fallback.
        let candidateURLs = (property.hlsUrl ?? [])
            + (property.directVideoUrls ?? [])
            + property.videoUrl
        let url = candidateURLs.compactMap { rawValue -> URL? in
            guard let candidate = URL(string: rawValue),
                  let scheme = candidate.scheme?.lowercased(),
                  (scheme == "https" || scheme == "http"),
                  candidate.host != nil
            else {
                return nil
            }
            return candidate
        }.first

        guard let url else { return nil }

        return FeedPlaybackItem(
            mediaId: mediaID,
            source: MediaSource(url: url),
            matchScore: property.matchScore,
            title: property.title,
            artist: property.ownerName
        )
    }

    public func itemBecameVisible(
        _ property: PropertyModel,
        previous: [PropertyModel],
        next: [PropertyModel]
    ) {
        guard let current = Self.playbackItem(for: property) else {
            // A dominant non-video card must end the previous video's autoplay.
            Task { await playbackCoordinator.pause() }
            return
        }
        playbackCoordinator.onItemVisible(
            current,
            previous: previous.compactMap(Self.playbackItem(for:)),
            next: next.compactMap(Self.playbackItem(for:))
        )
    }

    /// Tracks only media-bearing cards that SwiftUI currently composes. The
    /// player pool pins these identities so scrolling cannot recycle their engines.
    public func setComposed(_ property: PropertyModel, isComposed: Bool) {
        guard let item = Self.playbackItem(for: property) else { return }
        if isComposed {
            composedMediaIDs.insert(item.mediaId)
        } else {
            composedMediaIDs.remove(item.mediaId)
        }
        let snapshot = composedMediaIDs
        Task { await playbackCoordinator.updateComposedMedia(snapshot) }
    }

    public func playerEngine(for property: PropertyModel) async throws -> PlayerEngine {
        guard let item = Self.playbackItem(for: property) else {
            throw URLError(.badURL)
        }
        return try await playerManager.playerEngine(
            mediaId: item.mediaId,
            source: item.source
        )
    }

    public func toggleMute() {
        isMuted.toggle()
    }

    public func endFeed() {
        composedMediaIDs.removeAll()
        Task { [playbackCoordinator] in
            await playbackCoordinator.pause()
            playbackCoordinator.clear()
            await playbackCoordinator.updateComposedMedia([])
        }
    }
}
