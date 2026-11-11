import AVFoundation
import Foundation
import UniformTypeIdentifiers

private actor HLSResourceLoadingRequestState {
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var cancelledRequests: Set<ObjectIdentifier> = []

    func start(
        id: ObjectIdentifier,
        operation: @escaping @Sendable () async -> Void
    ) {
        if cancelledRequests.remove(id) != nil {
            return
        }

        let task = Task {
            await operation()
            finish(id: id)
        }
        tasks[id] = task
    }

    func cancel(id: ObjectIdentifier) {
        cancelledRequests.insert(id)
        tasks.removeValue(forKey: id)?.cancel()
    }

    func finish(id: ObjectIdentifier) {
        tasks.removeValue(forKey: id)
        cancelledRequests.remove(id)
    }

    func cancelAll() {
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll(keepingCapacity: false)
        cancelledRequests.removeAll(keepingCapacity: false)
    }
}

/// AVAssetResourceLoader delegate for Estatia-hosted HLS.
///
/// The root manifest and every HTTP(S) URI found inside a playlist are changed
/// to a private URL scheme. AVFoundation then asks this delegate to load each
/// request; the delegate fetches it using the shared CDN-aware fetcher and
/// rewrites any child playlist before returning the bytes.
final class HLSResourceLoader:
    NSObject,
    AVAssetResourceLoaderDelegate,
    @unchecked Sendable {

    private static let httpsScheme = "estatia-hls-https"
    private static let httpScheme = "estatia-hls-http"
    private static let chunkSize = 512 * 1024
    private static let maximumResourceBytes = 128 * 1024 * 1024

    private let rootSource: MediaSource
    private let fetcher: any MediaDataFetching
    private let requestState = HLSResourceLoadingRequestState()

    init(
        source: MediaSource,
        fetcher: any MediaDataFetching
    ) {
        self.rootSource = source
        self.fetcher = fetcher
        super.init()
    }

    static func supports(_ source: MediaSource) -> Bool {
        let isHLS =
            source.type == .hls ||
            source.url.pathExtension.lowercased() == "m3u8"

        guard isHLS,
              let host = source.url.host?.lowercased()
        else {
            return false
        }

        return isEstatiaHost(host)
    }

    static func proxyURL(for url: URL) -> URL? {
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }

        switch components.scheme?.lowercased() {
        case "https":
            components.scheme = httpsScheme
        case "http":
            components.scheme = httpScheme
        default:
            return nil
        }

        return components.url
    }

    static func originURL(forProxyURL url: URL) -> URL? {
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }

        switch components.scheme?.lowercased() {
        case httpsScheme:
            components.scheme = "https"
        case httpScheme:
            components.scheme = "http"
        default:
            return nil
        }

        return components.url
    }

    /// Routes every network URI in an HLS playlist through the resource loader.
    /// Relative paths are resolved against the containing playlist URL.
    static func rewritePlaylist(
        _ playlist: String,
        relativeTo baseURL: URL
    ) -> String {
        let hasCRLF = playlist.contains("\r\n")
        let normalized = playlist
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        guard normalized
            .drop(while: { $0.isWhitespace })
            .hasPrefix("#EXTM3U")
        else {
            return playlist
        }

        let lines = normalized.components(separatedBy: "\n")
        let rewritten = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return line }

            if trimmed.hasPrefix("#") {
                return rewriteURIAttributes(
                    in: line,
                    relativeTo: baseURL
                )
            }

            guard let resourceURL = URL(
                string: trimmed,
                relativeTo: baseURL
            )?.absoluteURL,
            let proxiedURL = proxyURL(for: resourceURL)
            else {
                return line
            }

            return line.replacingOccurrences(
                of: trimmed,
                with: proxiedURL.absoluteString
            )
        }

        return rewritten.joined(separator: hasCRLF ? "\r\n" : "\n")
    }

    /// Preserve authorization headers across Estatia's own CDN hosts, but
    /// don't forward origin credentials to an unrelated third-party host.
    static func requestSource(
        for resourceURL: URL,
        rootSource: MediaSource
    ) -> MediaSource {
        let rootHost = rootSource.url.host?.lowercased()
        let resourceHost = resourceURL.host?.lowercased()
        let sameEstatiaNetwork =
            rootHost.map(isEstatiaHost) == true &&
            resourceHost.map(isEstatiaHost) == true
        let sameHost = rootHost != nil && rootHost == resourceHost

        return MediaSource(
            url: resourceURL,
            type: .auto,
            headers: (sameHost || sameEstatiaNetwork) ? rootSource.headers : nil,
            metadata: rootSource.metadata
        )
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let proxyURL = loadingRequest.request.url,
              Self.originURL(forProxyURL: proxyURL) != nil
        else {
            return false
        }

        let identifier = ObjectIdentifier(loadingRequest)
        let request = loadingRequest
        let loader = self
        let operation: @Sendable () async -> Void = {
            await loader.process(
                request,
                proxyURL: proxyURL
            )
        }

        Task { [requestState, operation] in
            await requestState.start(
                id: identifier,
                operation: operation
            )
        }

        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let identifier = ObjectIdentifier(loadingRequest)
        Task { [requestState] in
            await requestState.cancel(id: identifier)
        }
    }

    private func process(
        _ loadingRequest: AVAssetResourceLoadingRequest,
        proxyURL: URL
    ) async {
        guard let originURL = Self.originURL(forProxyURL: proxyURL) else {
            loadingRequest.finishLoading(with: HLSResourceLoaderError.invalidURL)
            return
        }

        do {
            try Task.checkCancellation()
            let source = Self.requestSource(
                for: originURL,
                rootSource: rootSource
            )

            var metadataResponse: MediaDataFetchResponse?
            if loadingRequest.contentInformationRequest != nil {
                let response = try await fetcher.fetch(
                    source: source,
                    offset: 0,
                    length: Self.chunkSize
                )
                try Task.checkCancellation()
                try Self.validate(response)
                metadataResponse = response
                populateContentInformation(
                    loadingRequest.contentInformationRequest,
                    response: response,
                    originURL: originURL
                )
            }

            if let dataRequest = loadingRequest.dataRequest {
                let requestedOffset = dataRequest.currentOffset
                guard requestedOffset >= 0 else {
                    throw HLSResourceLoaderError.invalidRange
                }

                let requestedLength: Int64? =
                    dataRequest.requestsAllDataToEndOfResource
                    ? nil
                    : Int64(dataRequest.requestedLength)

                let prefetched =
                    requestedOffset == 0
                    ? metadataResponse
                    : nil

                var data = try await fetchData(
                    source: source,
                    offset: requestedOffset,
                    requestedLength: requestedLength,
                    prefetchedResponse: prefetched
                )

                try Task.checkCancellation()
                guard !loadingRequest.isCancelled else {
                    throw CancellationError()
                }

                let mimeType = metadataResponse?.contentType
                if requestedOffset == 0,
                   Self.isPlaylist(
                    data,
                    originURL: originURL,
                    mimeType: mimeType
                   ),
                   let playlist = String(data: data, encoding: .utf8) {
                    data = Data(
                        Self.rewritePlaylist(
                            playlist,
                            relativeTo: originURL
                        ).utf8
                    )
                }

                if !data.isEmpty {
                    dataRequest.respond(with: data)
                }
            }

            guard !loadingRequest.isCancelled else { return }
            loadingRequest.finishLoading()
        } catch is CancellationError {
            // AVFoundation already knows this request was cancelled.
        } catch {
            guard !loadingRequest.isCancelled else { return }
            loadingRequest.finishLoading(with: error as NSError)
        }
    }

    private func fetchData(
        source: MediaSource,
        offset initialOffset: Int64,
        requestedLength: Int64?,
        prefetchedResponse: MediaDataFetchResponse?
    ) async throws -> Data {
        var output = Data()
        var offset = initialOffset
        var remaining = requestedLength
        var pendingResponse = prefetchedResponse

        while remaining == nil || remaining! > 0 {
            try Task.checkCancellation()

            let requested = Int(
                min(
                    Int64(Self.chunkSize),
                    remaining ?? Int64(Self.chunkSize)
                )
            )
            guard requested > 0 else { break }

            let response: MediaDataFetchResponse
            if let prefetched = pendingResponse {
                response = prefetched
                pendingResponse = nil
            } else {
                response = try await fetcher.fetch(
                    source: source,
                    offset: offset,
                    length: requested
                )
            }

            try Self.validate(response)
            if response.statusCode == 416 {
                break
            }

            let bytes: Data
            if response.statusCode == 200 {
                // A server that ignores Range returns the full representation
                // from byte zero. Slice out the range AVFoundation requested.
                let start = Int(offset)
                guard start <= response.data.count else {
                    throw HLSResourceLoaderError.rangeNotSupported
                }
                let available = response.data.count - start
                let countToTake = remaining.map {
                    min(Int($0), available)
                } ?? available
                bytes = countToTake > 0
                    ? response.data.subdata(in: start..<(start + countToTake))
                    : Data()
            } else {
                bytes = Data(response.data.prefix(requested))
            }

            guard output.count + bytes.count <= Self.maximumResourceBytes else {
                throw HLSResourceLoaderError.resourceTooLarge
            }

            if !bytes.isEmpty {
                output.append(bytes)
                offset += Int64(bytes.count)
                if let currentRemaining = remaining {
                    remaining = max(0, currentRemaining - Int64(bytes.count))
                }
            }

            // 200 means the origin supplied a full body; there is nothing
            // further to request even when the original requested length is small.
            if response.statusCode == 200 ||
               bytes.isEmpty ||
               bytes.count < requested {
                break
            }

            if let totalLength = response.totalLength,
               offset >= totalLength {
                break
            }
        }

        return output
    }

    private func populateContentInformation(
        _ information: AVAssetResourceLoadingContentInformationRequest?,
        response: MediaDataFetchResponse,
        originURL: URL
    ) {
        guard let information else { return }

        if let mimeType = response.contentType,
           let type = UTType(mimeType: mimeType) {
            information.contentType = type.identifier
        } else if let fileExtension = originURL.pathExtension.nilIfEmpty,
                  let type = UTType(filenameExtension: fileExtension) {
            information.contentType = type.identifier
        }

        let inferredLength =
            response.statusCode == 200
            ? Int64(response.data.count)
            : nil
        information.contentLength =
            response.totalLength ??
            inferredLength ??
            0
        information.isByteRangeAccessSupported =
            response.statusCode == 206 ||
            response.totalLength != nil
    }

    private static func validate(
        _ response: MediaDataFetchResponse
    ) throws {
        guard response.statusCode == 200 ||
              response.statusCode == 206 ||
              response.statusCode == 416
        else {
            throw MediaDataFetchError.unacceptableStatus(
                response.statusCode
            )
        }
    }

    private static func isPlaylist(
        _ data: Data,
        originURL: URL,
        mimeType: String?
    ) -> Bool {
        if originURL.pathExtension.lowercased() == "m3u8" {
            return true
        }
        if let mimeType = mimeType?.lowercased(),
           mimeType.contains("mpegurl") {
            return true
        }
        guard let text = String(data: data.prefix(256), encoding: .utf8) else {
            return false
        }
        return text
            .drop(while: { $0.isWhitespace })
            .hasPrefix("#EXTM3U")
    }

    private static func rewriteURIAttributes(
        in line: String,
        relativeTo baseURL: URL
    ) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?i)\b(URI|SERVER-URI)\s*=\s*"([^"]*)""#
        ) else {
            return line
        }

        let matches = expression.matches(
            in: line,
            range: NSRange(line.startIndex..., in: line)
        )
        var rewritten = line

        for match in matches.reversed() {
            guard match.numberOfRanges > 2,
                  let valueRange = Range(match.range(at: 2), in: rewritten)
            else {
                continue
            }

            let rawURI = String(rewritten[valueRange])
            guard let resourceURL = URL(
                string: rawURI,
                relativeTo: baseURL
            )?.absoluteURL,
            let proxiedURL = proxyURL(for: resourceURL)
            else {
                continue
            }

            rewritten.replaceSubrange(
                valueRange,
                with: proxiedURL.absoluteString
            )
        }

        return rewritten
    }

    private static func isEstatiaHost(_ host: String) -> Bool {
        host == "estatia.com" || host.hasSuffix(".estatia.com")
    }

    deinit {
        let requestState = self.requestState
        Task {
            await requestState.cancelAll()
        }
    }
}

private enum HLSResourceLoaderError: Error {
    case invalidURL
    case invalidRange
    case rangeNotSupported
    case resourceTooLarge
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
