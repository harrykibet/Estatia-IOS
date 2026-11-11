import Foundation

/// Routes Estatia progressive byte-range requests through a configured CDN.
/// Each request gets at most one retry on a different endpoint.
public final class CdnFailoverMediaDataFetcher: MediaDataFetching, Sendable {
    private let baseFetcher: any MediaDataFetching
    private let selector: CdnSelector

    public init(
        baseFetcher: any MediaDataFetching = URLSessionMediaDataFetcher(),
        selector: CdnSelector
    ) {
        self.baseFetcher = baseFetcher
        self.selector = selector
    }

    public func fetch(
        source: MediaSource,
        offset: Int64,
        length: Int
    ) async throws -> MediaDataFetchResponse {
        guard Self.isEstatiaHost(source.url.host) else {
            return try await baseFetcher.fetch(source: source, offset: offset, length: length)
        }

        // Re-evaluate health for each request, even when an earlier cache-warm
        // step already rewrote the source to a configured CDN hostname.
        let initialCDN = await selector.selectBestCdn(forPath: source.url.path)

        guard let initialCDN,
              let initialSource = Self.source(source, routedTo: initialCDN)
        else {
            return try await baseFetcher.fetch(source: source, offset: offset, length: length)
        }

        let startedAt = Date()
        let firstResponse: MediaDataFetchResponse
        do {
            firstResponse = try await baseFetcher.fetch(
                source: initialSource,
                offset: offset,
                length: length
            )
        } catch {
            if Task.isCancelled || error is CancellationError { throw error }
            await selector.recordFailure(for: initialCDN)
            return try await retry(
                originalSource: source,
                offset: offset,
                length: length,
                failedCDN: initialCDN,
                firstError: error,
                firstResponse: nil
            )
        }

        guard Self.isAcceptedStatus(firstResponse.statusCode) else {
            await selector.recordFailure(for: initialCDN)
            return try await retry(
                originalSource: source,
                offset: offset,
                length: length,
                failedCDN: initialCDN,
                firstError: nil,
                firstResponse: firstResponse
            )
        }

        await selector.recordSuccess(
            for: initialCDN,
            latency: Date().timeIntervalSince(startedAt)
        )
        return firstResponse
    }

    private func retry(
        originalSource: MediaSource,
        offset: Int64,
        length: Int,
        failedCDN: Cdn,
        firstError: Error?,
        firstResponse: MediaDataFetchResponse?
    ) async throws -> MediaDataFetchResponse {
        guard let alternative = await selector.selectBestCdn(
            forPath: originalSource.url.path,
            excluding: [failedCDN.id]
        ),
        let alternativeSource = Self.source(originalSource, routedTo: alternative)
        else {
            if let firstResponse { return firstResponse }
            if let firstError { throw firstError }
            throw URLError(.cannotConnectToHost)
        }

        let startedAt = Date()
        do {
            let response = try await baseFetcher.fetch(
                source: alternativeSource,
                offset: offset,
                length: length
            )
            if Self.isAcceptedStatus(response.statusCode) {
                await selector.recordSuccess(
                    for: alternative,
                    latency: Date().timeIntervalSince(startedAt)
                )
            } else {
                await selector.recordFailure(for: alternative)
            }
            return response
        } catch {
            if Task.isCancelled || error is CancellationError { throw error }
            await selector.recordFailure(for: alternative)
            throw error
        }
    }

    private static func source(_ source: MediaSource, routedTo cdn: Cdn) -> MediaSource? {
        guard var components = URLComponents(url: source.url, resolvingAgainstBaseURL: false),
              let endpoint = URLComponents(url: cdn.baseURL, resolvingAgainstBaseURL: false),
              let host = endpoint.host
        else {
            return nil
        }

        components.scheme = endpoint.scheme ?? components.scheme
        components.host = host
        components.port = endpoint.port
        components.user = endpoint.user
        components.password = endpoint.password
        guard let url = components.url else { return nil }

        return MediaSource(
            url: url,
            type: source.type,
            headers: source.headers,
            metadata: source.metadata
        )
    }

    private static func isAcceptedStatus(_ statusCode: Int) -> Bool {
        statusCode == 200 || statusCode == 206 || statusCode == 416
    }

    private static func isEstatiaHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "estatia.com" || host.hasSuffix(".estatia.com")
    }
}
