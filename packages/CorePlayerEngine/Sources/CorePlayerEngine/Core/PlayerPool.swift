import Foundation

public enum PlayerPoolError:
    Error,
    Equatable,
    LocalizedError {

    case capacityExceeded
    case draining
    case releaseInProgress
    case acquisitionInvalidated

    public var errorDescription: String? {

        switch self {

        case .capacityExceeded:
            return """
            The player pool has reached capacity and all active players \
            are pinned.
            """

        case .draining:
            return """
            The player pool is currently releasing its resources and \
            cannot accept new players.
            """

        case .releaseInProgress:
            return """
            The player is being released and cannot be acquired until that operation completes.
            """

        case .acquisitionInvalidated:
            return """
            The player was released or invalidated before acquisition completed.
            """
        }
    }
}

@MainActor
public final class PlayerPool {

    // MARK: - Dependencies

    private let configuration:
        PlayerPoolConfiguration

    private let makeEngine:
        @MainActor () -> PlayerEngine

    // MARK: - State

    private var activePlayers:
        [String: ManagedPlayer] = [:]

    private var idlePlayers:
        [ManagedPlayer] = []

    private var allPlayers:
        [ManagedPlayer] = []

    private var pinnedMediaIds:
        Set<String> = []

    private var accessSequence:
        UInt64 = 0

    // MARK: - In-Flight Creation

    /// One creation task per media ID.
    ///
    /// This prevents:
    ///
    ///     request A ──┐
    ///                  ├── create two players
    ///     request A ──┘
    ///
    /// from occurring concurrently.
    ///
    /// Unrelated media IDs may still be created concurrently.
    private var inFlightCreations:
        [String: Task<ManagedPlayer, Error>] = [:]

    /// Stop operations are tracked separately because actor reentrancy allows
    /// releaseAll() to run while an individual engine.stop() is suspended.
    private var inFlightReleases:
        [String: Task<Void, Never>] = [:]

    private(set) var releasingMediaIds: Set<String> = []

    // MARK: - Lifecycle

    private(set) var isDraining = false
    private var lifecycleGeneration: UInt64 = 0
    private var releaseAllTask: Task<Void, Never>?

    // MARK: - Initialization

    public init(
        configuration: PlayerPoolConfiguration = PlayerPoolConfiguration(),
        factory: @escaping @MainActor () -> PlayerEngine
    ) {
        self.configuration = configuration
        self.makeEngine = factory
    }

    /// Creates a pool backed by the package's default AVFoundation engine.
    ///
    /// Tests and alternative integrations should inject a factory through
    /// the designated initializer to keep player construction deterministic.
    public convenience init(
        configuration: PlayerPoolConfiguration = PlayerPoolConfiguration()
    ) {
        self.init(
            configuration: configuration,
            factory: {
                PlayerEngineFactory.make()
            }
        )
    }

    // MARK: - Lookup

    public func get(
        mediaId: String
    ) async -> ManagedPlayer? {

        guard !isDraining,
              !releasingMediaIds.contains(mediaId)
        else {
            return nil
        }

        guard let managed =
                activePlayers[mediaId]
        else {
            return nil
        }

        touch(
            managed
        )

        return managed
    }

    // MARK: - Acquisition

    public func getOrCreate(
        mediaId: String,
        source: MediaSource
    ) async throws -> ManagedPlayer {

        guard !isDraining else {
            throw PlayerPoolError.draining
        }

        guard !releasingMediaIds.contains(mediaId) else {
            throw PlayerPoolError.releaseInProgress
        }

        let generation = lifecycleGeneration

        // IMPORTANT:
        // Check in-flight creation before active state.
        //
        // A creation task may have reserved this media ID while
        // the actual AVPlayer load is suspended.
        if let inFlight = inFlightCreations[mediaId] {
            let managed = try await inFlight.value

            return try validateAcquisition(
                managed,
                mediaId: mediaId,
                generation: generation
            )
        }

        if let existing = activePlayers[mediaId] {
            touch(existing)
            return existing
        }

        let creation = Task<ManagedPlayer, Error> { @MainActor [self] in
            try await createAndLoad(
                mediaId: mediaId,
                source: source
            )
        }

        inFlightCreations[mediaId] = creation

        let managed = try await creation.value

        return try validateAcquisition(
            managed,
            mediaId: mediaId,
            generation: generation
        )
    }

    // MARK: - Creation

    private func createAndLoad(
        mediaId: String,
        source: MediaSource
    ) async throws -> ManagedPlayer {

        defer {
            inFlightCreations.removeValue(
                forKey: mediaId
            )
        }

        let managed =
            try await acquirePlayer()

        do {
            try Task.checkCancellation()

            try await managed.engine.load(
                mediaId: mediaId,
                source: source
            )

            try Task.checkCancellation()
        } catch {
            // release() is terminal for PlayerEngine. A failed engine must
            // never be put back into the idle cache.
            //
            // During a pool drain, releaseAll() owns final disposal after it
            // has awaited this creation task. Disposing here as well would
            // release the same engine twice.
            if Task.isCancelled && isDraining {
                throw CancellationError()
            }

            try? await managed.engine.release()
            removeFromPool(managed)
            throw error
        }

        activate(
            managed,
            mediaId: mediaId
        )

        return managed
    }

    // MARK: - Prewarm

    public func prewarm(
        mediaId: String,
        source: MediaSource
    ) async -> Bool {

        do {

            _ = try await getOrCreate(
                mediaId: mediaId,
                source: source
            )

            return true

        } catch {

            return false
        }
    }

    // MARK: - Release

    public func release(
        mediaId: String
    ) async {
        // Coalesce repeated release requests for the same media identity.
        if let existingTask = inFlightReleases[mediaId] {
            await existingTask.value
            return
        }

        guard !isDraining else {
            return
        }

        guard activePlayers[mediaId] != nil ||
              inFlightCreations[mediaId] != nil
        else {
            return
        }

        releasingMediaIds.insert(mediaId)
        let generation = lifecycleGeneration

        // Releasing a media identity also cancels a load that has not yet
        // become active. getOrCreate() rejects new work until this completes.
        let task = Task { @MainActor [self] in
            await finishRelease(
                mediaId: mediaId,
                generation: generation
            )
        }

        inFlightReleases[mediaId] = task
        await task.value
    }

    private func finishRelease(
        mediaId: String,
        generation: UInt64
    ) async {
        defer {
            releasingMediaIds.remove(mediaId)
            inFlightReleases.removeValue(forKey: mediaId)
        }

        if let creation = inFlightCreations[mediaId] {
            creation.cancel()
            _ = try? await creation.value
        }

        // A pool drain takes ownership if it started while this release was
        // waiting for a load or stop operation.
        guard !isDraining, generation == lifecycleGeneration else {
            return
        }

        guard let managed = activePlayers.removeValue(forKey: mediaId) else {
            return
        }

        do {
            try await managed.engine.stop()
        } catch {
            guard !isDraining, generation == lifecycleGeneration else {
                return
            }

            try? await managed.engine.release()
            removeFromPool(managed)
            return
        }

        guard !isDraining, generation == lifecycleGeneration else {
            return
        }

        managed.markIdle()

        if idlePlayers.count < configuration.maxIdlePlayers {
            idlePlayers.append(managed)
        } else {
            try? await managed.engine.release()
            removeFromPool(managed)
        }
    }

    // MARK: - Release All

    public func releaseAll() async {
        // Concurrent callers join the same drain. Returning early here would
        // violate releaseAll()'s completion contract.
        if let existingTask = releaseAllTask {
            await existingTask.value
            return
        }

        isDraining = true
        lifecycleGeneration &+= 1

        let pendingCreations = Array(inFlightCreations.values)
        let pendingReleases = Array(inFlightReleases.values)

        for task in pendingCreations {
            task.cancel()
        }

        let task = Task { @MainActor [self] in
            await finishReleaseAll(
                pendingCreations: pendingCreations,
                pendingReleases: pendingReleases
            )
        }

        releaseAllTask = task
        await task.value
    }

    private func finishReleaseAll(
        pendingCreations: [Task<ManagedPlayer, Error>],
        pendingReleases: [Task<Void, Never>]
    ) async {
        // A creation may be suspended inside load(), and a release may be
        // suspended inside stop(). Both must finish before terminal disposal.
        for task in pendingCreations {
            _ = try? await task.value
        }

        for task in pendingReleases {
            await task.value
        }

        let players = allPlayers

        // Remove logical ownership before the first terminal release suspends.
        activePlayers.removeAll(keepingCapacity: false)
        idlePlayers.removeAll(keepingCapacity: false)
        pinnedMediaIds.removeAll(keepingCapacity: false)
        releasingMediaIds.removeAll(keepingCapacity: false)
        allPlayers.removeAll(keepingCapacity: false)
        inFlightCreations.removeAll(keepingCapacity: false)
        inFlightReleases.removeAll(keepingCapacity: false)

        for managed in players {
            try? await managed.engine.release()
            managed.markIdle()
        }

        isDraining = false
        releaseAllTask = nil
    }

    // MARK: - Pinning

    public func updatePinnedIds(
        _ pinned: Set<String>
    ) async {

        guard !isDraining else {
            return
        }

        pinnedMediaIds =
            pinned

        for managed in
            activePlayers.values {

            managed.markPinned(
                pinned.contains(
                    managed.mediaId ?? ""
                )
            )
        }
    }

    // MARK: - Snapshot

    public func activePlayersSnapshot()
        async -> [ManagedPlayer] {

        guard !isDraining else {
            return []
        }

        return activePlayers.values.filter {
            !releasingMediaIds.contains($0.mediaId ?? "")
        }
    }

    // MARK: - Capacity

    private func acquirePlayer()
        async throws -> ManagedPlayer {

        // A creation task can resume here after an awaited eviction operation.
        // Never allocate or recycle another engine once a drain has begun.
        try Task.checkCancellation()

        guard !isDraining else {
            throw PlayerPoolError.draining
        }

        // 1. Reuse idle resources first.
        if let idle =
            idlePlayers.popLast() {

            return idle
        }

        // 2. Create if capacity exists.
        if allPlayers.count <
            configuration.maxPlayers {

            let managed =
                ManagedPlayer(
                    engine: makeEngine()
                )

            allPlayers.append(
                managed
            )

            return managed
        }

        // 3. Recycle least-recently-used unpinned player.
        guard let evictable =
            leastRecentlyUsedEvictablePlayer()
        else {

            throw PlayerPoolError.capacityExceeded
        }

        guard let mediaId =
                evictable.mediaId
        else {

            removeFromPool(
                evictable
            )

            return try await acquirePlayer()
        }

        activePlayers.removeValue(
            forKey: mediaId
        )

        do {
            try await evictable.engine.stop()
            try Task.checkCancellation()
        } catch {
            if Task.isCancelled && isDraining {
                // releaseAll() will dispose this still-owned resource after
                // awaiting the creation task.
                throw CancellationError()
            }

            try? await evictable.engine.release()
            removeFromPool(evictable)
            return try await acquirePlayer()
        }

        evictable.markIdle()

        return evictable
    }

    private func validateAcquisition(
        _ managed: ManagedPlayer,
        mediaId: String,
        generation: UInt64
    ) throws -> ManagedPlayer {
        guard !isDraining, generation == lifecycleGeneration else {
            throw PlayerPoolError.draining
        }

        guard activePlayers[mediaId] === managed else {
            throw PlayerPoolError.acquisitionInvalidated
        }

        touch(managed)
        return managed
    }

    // MARK: - Activation

    private func activate(
        _ managed: ManagedPlayer,
        mediaId: String
    ) {

        accessSequence &+= 1

        managed.activate(
            mediaId: mediaId,
            sequence: accessSequence,
            pinned:
                pinnedMediaIds.contains(
                    mediaId
                )
        )

        activePlayers[mediaId] =
            managed
    }

    private func touch(
        _ managed: ManagedPlayer
    ) {

        accessSequence &+= 1

        managed.touch(
            sequence: accessSequence
        )
    }

    // MARK: - Eviction

    private func
        leastRecentlyUsedEvictablePlayer()
        -> ManagedPlayer?
    {

        activePlayers.values
            .filter {
                !$0.pinned
            }
            .min {
                $0.lastUsedSequence <
                $1.lastUsedSequence
            }
    }

    // MARK: - Pool Membership

    private func removeFromPool(
        _ managed: ManagedPlayer
    ) {

        idlePlayers.removeAll {
            $0 === managed
        }

        allPlayers.removeAll {
            $0 === managed
        }
    }

    // MARK: - Diagnostics

    public var activeCount: Int {
        activePlayers.count
    }

    public var idleCount: Int {
        idlePlayers.count
    }

    public var retainedPlayerCount: Int {
        allPlayers.count
    }

    public var inFlightCreationCount: Int {
        inFlightCreations.count
    }

    public var maxPlayers: Int {
        configuration.maxPlayers
    }

    public func contains(
        mediaId: String
    ) async -> Bool {

        await get(
            mediaId: mediaId
        ) != nil
    }

    public func hasDuplicateInstances() -> Bool {

        let identifiers =
            allPlayers.map {
                ObjectIdentifier(
                    $0.engine
                )
            }

        return Set(
            identifiers
        ).count != identifiers.count
    }
}
