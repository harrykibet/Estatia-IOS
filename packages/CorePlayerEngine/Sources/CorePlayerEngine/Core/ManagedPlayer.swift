import Foundation

@MainActor
public final class ManagedPlayer {

    public let engine: PlayerEngine

    public private(set) var mediaId: String?

    public private(set) var pinned: Bool

    /// Monotonic logical access sequence used for deterministic LRU eviction.
    public private(set) var lastUsedSequence: UInt64

    /// Serializes mutations against this engine while allowing independent
    /// managed players to progress concurrently.
    private var operationTail: Task<Void, Never>?

    /// Includes running and queued operations; useful for pool diagnostics.
    private(set) var pendingOperationCount = 0

    internal init(
        engine: PlayerEngine,
        mediaId: String? = nil
    ) {
        self.engine = engine
        self.mediaId = mediaId
        self.pinned = false
        self.lastUsedSequence = 0
    }

    /// Runs a mutating engine operation after all earlier operations for this
    /// managed player have completed. Errors are returned to the caller while
    /// the queue tail itself always completes, so one failed command cannot
    /// poison subsequent lifecycle operations.
    internal func perform(
        _ operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        pendingOperationCount += 1
        defer {
            pendingOperationCount -= 1
        }

        let previousOperation = operationTail

        let operationTask = Task { @MainActor in
            await previousOperation?.value
            try await operation()
        }

        operationTail = Task { @MainActor in
            _ = try? await operationTask.value
        }

        try await operationTask.value
    }

    /// Retained for source compatibility with callers that explicitly construct
    /// a managed player. Normal application code should obtain instances from
    /// PlayerPool.
    internal convenience init(
        mediaId: String,
        engine: PlayerEngine
    ) {
        self.init(
            engine: engine,
            mediaId: mediaId
        )
    }

    internal func activate(
        mediaId: String,
        sequence: UInt64,
        pinned: Bool
    ) {
        self.mediaId = mediaId
        self.lastUsedSequence = sequence
        self.pinned = pinned
    }

    internal func touch(sequence: UInt64) {
        self.lastUsedSequence = sequence
    }

    internal func markPinned(_ pinned: Bool) {
        self.pinned = pinned
    }

    internal func markIdle() {
        self.mediaId = nil
        self.pinned = false
        self.lastUsedSequence = 0
    }
}
