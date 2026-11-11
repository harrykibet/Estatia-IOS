import AVFoundation
import CryptoKit
import Foundation

/// Persists completed media and tracks native progressive/HLS download tasks.
///
/// Progressive resources are downloaded as files. HLS resources use
/// AVAssetDownloadURLSession so playlists, segments, and renditions are stored
/// as one playable offline package rather than incorrectly saving only the
/// top-level manifest.
public final class OfflineDownloadController:
    NSObject,
    OfflineMediaResolving,
    URLSessionDownloadDelegate,
    @unchecked Sendable {

    public static let progressiveBackgroundSessionIdentifier = "com.application.estatia.offline-progressive.v1"
    public static let hlsBackgroundSessionIdentifier = "com.application.estatia.offline-hls.v1"

    private let rootDirectory: URL
    private let registryURL: URL
    private let stateQueue = DispatchQueue(
        label: "com.estatia.coreplayerengine.offline-download-state",
        qos: .utility
    )
    private let delegateQueue: OperationQueue
    private let usesBackgroundSessions: Bool
    private var progressiveSession: URLSession!
    #if os(iOS)
    private var hlsSession: AVAssetDownloadURLSession?
    #endif

    // All properties below are confined to stateQueue.
    private var records: [String: OfflineDownloadRecord] = [:]
    private var tasks: [String: URLSessionTask] = [:]
    private var observers: [UUID: AsyncStream<[OfflineDownloadRecord]>.Continuation] = [:]
    private let backgroundCompletionLock = NSLock()
    private var backgroundCompletionHandlers: [String: () -> Void] = [:]

    public init(
        rootDirectory: URL = OfflineDownloadController.defaultRootDirectory(),
        usesBackgroundSessions: Bool = true
    ) {
        self.rootDirectory = rootDirectory
        self.registryURL = rootDirectory.appendingPathComponent("downloads.plist")
        self.usesBackgroundSessions = usesBackgroundSessions

        let delegateQueue = OperationQueue()
        delegateQueue.name = "com.estatia.coreplayerengine.offline-download-delegates"
        delegateQueue.maxConcurrentOperationCount = 1
        self.delegateQueue = delegateQueue

        super.init()

        #if os(iOS)
        let progressiveConfiguration: URLSessionConfiguration
        if usesBackgroundSessions {
            let background = URLSessionConfiguration.background(
                withIdentifier: Self.progressiveBackgroundSessionIdentifier
            )
            background.isDiscretionary = false
            background.sessionSendsLaunchEvents = true
            progressiveConfiguration = background
        } else {
            progressiveConfiguration = .ephemeral
        }
        self.progressiveSession = URLSession(
            configuration: progressiveConfiguration,
            delegate: self,
            delegateQueue: delegateQueue
        )

        if usesBackgroundSessions {
            self.hlsSession = makeHLSDownloadSession()
        }
        #else
        self.progressiveSession = URLSession(
            configuration: .ephemeral,
            delegate: self,
            delegateQueue: delegateQueue
        )
        #endif

        try? FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        loadRegistry()
        restoreActiveTasks()
    }

    private static func defaultRootDirectory() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("Estatia/OfflineMedia/v1", isDirectory: true)
    }

    /// Stores the system completion handler until URLSession has delivered all
    /// background events for one of this controller's sessions.
    public func handleBackgroundSessionEvents(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == Self.progressiveBackgroundSessionIdentifier ||
              identifier == Self.hlsBackgroundSessionIdentifier
        else {
            completionHandler()
            return
        }
        backgroundCompletionLock.withLock {
            backgroundCompletionHandlers[identifier] = completionHandler
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        let completion = backgroundCompletionLock.withLock {
            backgroundCompletionHandlers.removeValue(forKey: identifier)
        }
        completion?()
    }

    /// Starts a durable offline download. Repeated requests for the same active
    /// or already-completed source are idempotent.
    public func scheduleDownload(mediaId: String, source: MediaSource) throws {
        guard !mediaId.isEmpty,
              let scheme = source.url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            throw OfflineDownloadError.invalidSource
        }

        let kind = try Self.kind(for: source)
        let fingerprint = Self.fingerprint(for: source.url)
        let fileExtension = Self.fileExtension(for: source.url, kind: kind)

        try stateQueue.sync {
            if let existing = records[mediaId],
               existing.sourceFingerprint == fingerprint {
                if existing.status == .queued || existing.status == .downloading {
                    return
                }
                if existing.status == .completed,
                   let localURL = existing.localURL,
                   FileManager.default.fileExists(atPath: localURL.path) {
                    return
                }
            }

            if let previous = tasks.removeValue(forKey: mediaId) {
                previous.cancel()
            }
            if let previousURL = records[mediaId]?.localURL {
                try? FileManager.default.removeItem(at: previousURL)
            }

            var request = URLRequest(url: source.url)
            request.httpMethod = "GET"
            request.timeoutInterval = 60
            source.headers?.forEach { key, value in
                request.setValue(value, forHTTPHeaderField: key)
            }

            let task: URLSessionTask
            switch kind {
            case .progressive:
                task = progressiveSession.downloadTask(with: request)

            case .hls:
                #if os(iOS)
                var assetOptions: [String: Any] = [:]
                if let headers = source.headers {
                    assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = headers
                }
                let asset = AVURLAsset(url: source.url, options: assetOptions)
                let session = hlsSession ?? makeHLSDownloadSession()
                guard let downloadTask = session.makeAssetDownloadTask(
                    asset: asset,
                    assetTitle: mediaId,
                    assetArtworkData: nil,
                    options: nil
                ) else {
                    throw OfflineDownloadError.invalidSource
                }
                task = downloadTask
                #else
                throw OfflineDownloadError.hlsRequiresIOS
                #endif
            }

            task.taskDescription = mediaId
            records[mediaId] = OfflineDownloadRecord(
                mediaId: mediaId,
                kind: kind,
                fileExtension: fileExtension,
                status: .queued,
                progress: 0,
                totalBytesWritten: 0,
                totalBytesExpected: nil,
                localURL: nil,
                failureReason: nil,
                updatedAt: Date(),
                sourceFingerprint: fingerprint
            )
            tasks[mediaId] = task
            persistRegistry()
            publishSnapshot()

            task.resume()
            records[mediaId] = records[mediaId]?.replacing(status: .downloading)
            persistRegistry()
            publishSnapshot()
        }
    }

    /// Cancels an active transfer but retains a visible cancelled record.
    public func cancelDownload(mediaId: String) {
        stateQueue.sync {
            tasks.removeValue(forKey: mediaId)?.cancel()
            if let record = records[mediaId] {
                records[mediaId] = record.replacing(status: .cancelled)
                persistRegistry()
                publishSnapshot()
            }
        }
    }

    /// Cancels the transfer and removes both its registry entry and local asset.
    public func removeDownload(mediaId: String) {
        stateQueue.sync {
            tasks.removeValue(forKey: mediaId)?.cancel()
            if let localURL = records[mediaId]?.localURL {
                try? FileManager.default.removeItem(at: localURL)
            }
            records.removeValue(forKey: mediaId)
            persistRegistry()
            publishSnapshot()
        }
    }

    public func observeDownloads() -> AsyncStream<[OfflineDownloadRecord]> {
        let observerID = UUID()
        return AsyncStream { continuation in
            stateQueue.async {
                self.observers[observerID] = continuation
                continuation.yield(self.snapshot())
            }
            continuation.onTermination = { [weak self] _ in
                self?.stateQueue.async {
                    self?.observers.removeValue(forKey: observerID)
                }
            }
        }
    }

    public func offlineSource(
        for mediaId: String,
        originalSource: MediaSource
    ) async -> MediaSource? {
        stateQueue.sync {
            guard let record = records[mediaId],
                  record.status == .completed,
                  record.sourceFingerprint == Self.fingerprint(for: originalSource.url),
                  let localURL = record.localURL,
                  FileManager.default.fileExists(atPath: localURL.path)
            else {
                return nil
            }

            return MediaSource(
                url: localURL,
                type: .file,
                headers: nil,
                metadata: originalSource.metadata
            )
        }
    }

    // MARK: - URLSessionDownloadDelegate

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let mediaId = downloadTask.taskDescription else { return }
        stateQueue.async {
            guard let record = self.records[mediaId],
                  record.status == .downloading
            else {
                return
            }
            let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
            let progress = expected.map { Double(totalBytesWritten) / Double($0) } ?? 0
            self.records[mediaId] = record.replacing(
                status: .downloading,
                progress: progress,
                totalBytesWritten: totalBytesWritten,
                totalBytesExpected: .some(expected)
            )
            self.persistRegistry()
            self.publishSnapshot()
        }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let mediaId = downloadTask.taskDescription else { return }
        guard let response = downloadTask.response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode)
        else {
            finishWithFailure(
                mediaId: mediaId,
                reason: "The server returned an unsuccessful download response."
            )
            return
        }
        moveDownloadedAsset(location, mediaId: mediaId)
    }

    // MARK: - AVAssetDownloadDelegate

    #if os(iOS)
    public func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didLoad time: CMTime,
        totalTimeRangesLoaded loadedTimeRanges: [NSValue],
        timeRangeExpectedToLoad: CMTimeRange
    ) {
        guard let mediaId = assetDownloadTask.taskDescription else { return }
        let expected = timeRangeExpectedToLoad.duration.seconds
        let loaded = loadedTimeRanges.reduce(0.0) { total, value in
            total + value.timeRangeValue.duration.seconds
        }
        let progress = expected.isFinite && expected > 0 ? loaded / expected : 0
        stateQueue.async {
            guard let record = self.records[mediaId],
                  record.status == .downloading
            else {
                return
            }
            self.records[mediaId] = record.replacing(
                status: .downloading,
                progress: progress
            )
            self.persistRegistry()
            self.publishSnapshot()
        }
    }

    public func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let mediaId = assetDownloadTask.taskDescription else { return }
        moveDownloadedAsset(location, mediaId: mediaId)
    }
    #endif

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let mediaId = task.taskDescription else { return }
        stateQueue.async {
            self.tasks.removeValue(forKey: mediaId)
            guard let record = self.records[mediaId] else { return }

            // A successful download callback has already installed the artifact.
            if error == nil || record.status == .completed || record.status == .cancelled {
                return
            }

            let nsError = error as NSError?
            if nsError?.code == URLError.cancelled.rawValue {
                self.records[mediaId] = record.replacing(status: .cancelled)
            } else {
                self.records[mediaId] = record.replacing(
                    status: .failed,
                    failureReason: .some(error?.localizedDescription ?? "Download failed.")
                )
            }
            self.persistRegistry()
            self.publishSnapshot()
        }
    }

    // MARK: - Internal state

    private func moveDownloadedAsset(_ temporaryURL: URL, mediaId: String) {
        stateQueue.async {
            guard let record = self.records[mediaId],
                  record.status == .downloading
            else {
                return
            }

            let destination = self.rootDirectory
                .appendingPathComponent(Self.stableName(for: mediaId))
                .appendingPathExtension(record.kind == .hls ? "movpkg" : record.fileExtension)

            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                self.records[mediaId] = record.replacing(
                    status: .completed,
                    progress: 1,
                    localURL: .some(destination),
                    failureReason: .some(nil)
                )
            } catch {
                self.records[mediaId] = record.replacing(
                    status: .failed,
                    failureReason: .some(error.localizedDescription)
                )
            }

            self.tasks.removeValue(forKey: mediaId)
            self.persistRegistry()
            self.publishSnapshot()
        }
    }

    private func finishWithFailure(mediaId: String, reason: String) {
        stateQueue.async {
            guard let record = self.records[mediaId],
                  record.status == .downloading
            else {
                return
            }
            self.records[mediaId] = record.replacing(
                status: .failed,
                failureReason: .some(reason)
            )
            self.tasks.removeValue(forKey: mediaId)
            self.persistRegistry()
            self.publishSnapshot()
        }
    }

    private func loadRegistry() {
        stateQueue.sync {
            guard let data = try? Data(contentsOf: registryURL),
                  let decoded = try? PropertyListDecoder().decode(
                    [String: OfflineDownloadRecord].self,
                    from: data
                  )
            else {
                return
            }
            records = decoded
        }
    }

    #if os(iOS)
    private func makeHLSDownloadSession() -> AVAssetDownloadURLSession {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: Self.hlsBackgroundSessionIdentifier
        )
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        return AVAssetDownloadURLSession(
            configuration: configuration,
            assetDownloadDelegate: self,
            delegateQueue: delegateQueue
        )
    }
    #endif

    private func restoreActiveTasks() {
        progressiveSession.getAllTasks { [weak self] activeTasks in
            self?.restore(tasks: activeTasks)
        }
        #if os(iOS)
        hlsSession?.getAllTasks { [weak self] activeTasks in
            self?.restore(tasks: activeTasks)
        }
        #endif
    }

    private func restore(tasks activeTasks: [URLSessionTask]) {
        stateQueue.async {
            for task in activeTasks {
                guard let mediaId = task.taskDescription,
                      let record = self.records[mediaId],
                      record.status == .queued || record.status == .downloading
                else {
                    task.cancel()
                    continue
                }
                self.tasks[mediaId] = task
                if record.status == .queued {
                    self.records[mediaId] = record.replacing(status: .downloading)
                }
            }
            self.persistRegistry()
            self.publishSnapshot()
        }
    }

    private func snapshot() -> [OfflineDownloadRecord] {
        records.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func publishSnapshot() {
        let current = snapshot()
        for continuation in observers.values {
            continuation.yield(current)
        }
    }

    private func persistRegistry() {
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(records)
            try data.write(to: registryURL, options: .atomic)
        } catch {
            NSLog(
                "[OfflineDownloadController] Could not persist download registry: %@",
                error.localizedDescription
            )
        }
    }

    private static func kind(for source: MediaSource) throws -> OfflineDownloadKind {
        switch source.type {
        case .progressive:
            return .progressive
        case .hls:
            return .hls
        case .auto:
            return source.url.pathExtension.lowercased() == "m3u8" ? .hls : .progressive
        case .dash, .file:
            throw OfflineDownloadError.unsupportedMediaType
        }
    }

    private static func fileExtension(for url: URL, kind: OfflineDownloadKind) -> String {
        guard kind == .progressive else { return "movpkg" }
        let ext = url.pathExtension.lowercased()
        let safe = ext.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
        }
        return !ext.isEmpty && ext.count <= 10 && safe ? ext : "media"
    }

    private static func fingerprint(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func stableName(for mediaId: String) -> String {
        SHA256.hash(data: Data(mediaId.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}

#if os(iOS)
extension OfflineDownloadController: AVAssetDownloadDelegate {}
#endif
