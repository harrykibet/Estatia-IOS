//
//  StreamingPipeline.swift
//  CorePlayerEngine
//
//  Created by builder on 9/20/26.
//

import Foundation

public protocol StreamingPipeline: Sendable {

    func warm(
        mediaId: String,
        source: MediaSource,
        priority: WarmPriority
    ) async

    func downloadOffline(
        mediaId: String,
        source: MediaSource
    ) async throws

    func cancelOfflineDownload(mediaId: String)

    func removeOfflineDownload(mediaId: String)

    func observeOfflineDownloads() -> AsyncStream<[OfflineDownloadRecord]>
}

public extension StreamingPipeline {
    func downloadOffline(
        mediaId: String,
        source: MediaSource
    ) async throws {
        throw OfflineDownloadError.unsupportedMediaType
    }

    func cancelOfflineDownload(mediaId: String) {}

    func removeOfflineDownload(mediaId: String) {}

    func observeOfflineDownloads() -> AsyncStream<[OfflineDownloadRecord]> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}
