import CryptoKit
import Foundation
import XCTest
@testable import CorePlayerEngine

final class OfflineDownloadControllerTests: XCTestCase {

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineDownloadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func fingerprint(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func testRestoredCompletedDownloadResolvesOnlyForMatchingSignedSource() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = URL(string: "https://cdn.estatia.com/video.mp4?token=signed-secret")!
        let localURL = directory.appendingPathComponent("offline-video.mp4")
        try Data("offline video bytes".utf8).write(to: localURL)

        let record = OfflineDownloadRecord(
            mediaId: "property-video-1",
            kind: .progressive,
            fileExtension: "mp4",
            status: .completed,
            progress: 1,
            totalBytesWritten: 19,
            totalBytesExpected: 19,
            localURL: localURL,
            failureReason: nil,
            updatedAt: Date(),
            sourceFingerprint: fingerprint(sourceURL)
        )

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let registry = try encoder.encode(["property-video-1": record])
        try registry.write(
            to: directory.appendingPathComponent("downloads.plist"),
            options: .atomic
        )

        let controller = OfflineDownloadController(rootDirectory: directory)
        let originalSource = MediaSource(url: sourceURL, type: .progressive)
        let resolved = await controller.offlineSource(
            for: "property-video-1",
            originalSource: originalSource
        )

        XCTAssertEqual(resolved?.url, localURL)
        XCTAssertEqual(resolved?.type, .file)

        let changedSignedURL = URL(
            string: "https://cdn.estatia.com/video.mp4?token=rotated-secret"
        )!
        let changedSource = MediaSource(url: changedSignedURL, type: .progressive)
        let mismatched = await controller.offlineSource(
            for: "property-video-1",
            originalSource: changedSource
        )
        XCTAssertNil(mismatched)
    }

    func testRegistryDoesNotPersistTheOriginalSignedURL() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = URL(string: "https://cdn.estatia.com/video.mp4?token=do-not-persist")!
        let record = OfflineDownloadRecord(
            mediaId: "video-2",
            kind: .progressive,
            fileExtension: "mp4",
            status: .queued,
            progress: 0,
            totalBytesWritten: 0,
            totalBytesExpected: nil,
            localURL: nil,
            failureReason: nil,
            updatedAt: Date(),
            sourceFingerprint: fingerprint(sourceURL)
        )

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(["video-2": record])
        let persistedText = String(decoding: data, as: ISO Latin1.self)

        XCTAssertFalse(persistedText.contains("do-not-persist"))
        XCTAssertFalse(persistedText.contains(sourceURL.absoluteString))
    }

    func testUnsupportedDASHDownloadIsRejected() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = OfflineDownloadController(rootDirectory: directory)
        let source = MediaSource(
            url: URL(string: "https://cdn.estatia.com/video.mpd")!,
            type: .dash
        )

        XCTAssertThrowsError(
            try controller.scheduleDownload(mediaId: "dash-video", source: source)
        ) { error in
            XCTAssertEqual(error as? OfflineDownloadError, .unsupportedMediaType)
        }
    }

    func testNonHTTPSourceIsRejected() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = OfflineDownloadController(rootDirectory: directory)
        let source = MediaSource(
            url: URL(fileURLWithPath: "/tmp/video.mp4"),
            type: .progressive
        )

        XCTAssertThrowsError(
            try controller.scheduleDownload(mediaId: "local-video", source: source)
        ) { error in
            XCTAssertEqual(error as? OfflineDownloadError, .invalidSource)
        }
    }

    func testObservationStartsWithPersistedRegistrySnapshot() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = URL(string: "https://cdn.estatia.com/video.mp4")!
        let record = OfflineDownloadRecord(
            mediaId: "video-3",
            kind: .progressive,
            fileExtension: "mp4",
            status: .failed,
            progress: 0.4,
            totalBytesWritten: 40,
            totalBytesExpected: 100,
            localURL: nil,
            failureReason: "Network unavailable",
            updatedAt: Date(),
            sourceFingerprint: fingerprint(sourceURL)
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(["video-3": record]).write(
            to: directory.appendingPathComponent("downloads.plist"),
            options: .atomic
        )

        let controller = OfflineDownloadController(rootDirectory: directory)
        var iterator = controller.observeDownloads().makeAsyncIterator()
        let snapshot = await iterator.next()

        XCTAssertEqual(snapshot?.count, 1)
        XCTAssertEqual(snapshot?.first?.mediaId, "video-3")
        XCTAssertEqual(snapshot?.first?.status, .failed)
        XCTAssertEqual(snapshot?.first?.progress, 0.4)
    }

    #if !os(iOS)
    func testHLSDownloadReportsThatNativeOfflineHLSRequiresIOS() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = OfflineDownloadController(rootDirectory: directory)
        let source = MediaSource(
            url: URL(string: "https://cdn.estatia.com/master.m3u8")!,
            type: .hls
        )

        XCTAssertThrowsError(
            try controller.scheduleDownload(mediaId: "hls-video", source: source)
        ) { error in
            XCTAssertEqual(error as? OfflineDownloadError, .hlsRequiresIOS)
        }
    }
    #endif
}
