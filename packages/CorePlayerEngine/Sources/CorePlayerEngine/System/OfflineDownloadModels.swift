import Foundation
import CryptoKit

public enum OfflineDownloadKind: String, Codable, Sendable {
    case progressive
    case hls
}

public enum OfflineDownloadStatus: String, Codable, Sendable {
    case queued
    case downloading
    case completed
    case failed
    case cancelled
}

/// A durable snapshot of one requested offline media item.
public struct OfflineDownloadRecord: Codable, Sendable, Equatable, Identifiable {
    public let mediaId: String
    public let kind: OfflineDownloadKind
    public let fileExtension: String
    public let status: OfflineDownloadStatus
    public let progress: Double
    public let totalBytesWritten: Int64
    public let totalBytesExpected: Int64?
    public let localURL: URL?
    public let failureReason: String?
    public let updatedAt: Date

    // A one-way digest avoids persisting signed source URLs and query tokens.
    let sourceFingerprint: String
    let taskToken: String

    public var id: String { mediaId }

    init(
        mediaId: String,
        kind: OfflineDownloadKind,
        fileExtension: String,
        status: OfflineDownloadStatus,
        progress: Double,
        totalBytesWritten: Int64,
        totalBytesExpected: Int64?,
        localURL: URL?,
        failureReason: String?,
        updatedAt: Date,
        sourceFingerprint: String,
        taskToken: String
    ) {
        self.mediaId = mediaId
        self.kind = kind
        self.fileExtension = fileExtension
        self.status = status
        self.progress = min(1, max(0, progress))
        self.totalBytesWritten = max(0, totalBytesWritten)
        self.totalBytesExpected = totalBytesExpected
        self.localURL = localURL
        self.failureReason = failureReason
        self.updatedAt = updatedAt
        self.sourceFingerprint = sourceFingerprint
        self.taskToken = taskToken
    }
}

public enum OfflineDownloadError: Error, Equatable {
    case invalidSource
    case unsupportedMediaType
    case hlsRequiresIOS
}

/// Resolves a completed offline artifact without changing the logical media ID.
public protocol OfflineMediaResolving: Sendable {
    func offlineSource(
        for mediaId: String,
        originalSource: MediaSource
    ) async -> MediaSource?
}

extension OfflineDownloadRecord {
    func replacing(
        status: OfflineDownloadStatus,
        progress: Double? = nil,
        totalBytesWritten: Int64? = nil,
        totalBytesExpected: Int64?? = nil,
        localURL: URL?? = nil,
        failureReason: String?? = nil
    ) -> OfflineDownloadRecord {
        OfflineDownloadRecord(
            mediaId: mediaId,
            kind: kind,
            fileExtension: fileExtension,
            status: status,
            progress: progress ?? self.progress,
            totalBytesWritten: totalBytesWritten ?? self.totalBytesWritten,
            totalBytesExpected: totalBytesExpected ?? self.totalBytesExpected,
            localURL: localURL ?? self.localURL,
            failureReason: failureReason ?? self.failureReason,
            updatedAt: Date(),
            sourceFingerprint: sourceFingerprint,
            taskToken: taskToken
        )
    }
}
