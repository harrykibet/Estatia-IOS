import Foundation

@available(iOS 18.0, macOS 10.15, *)
public final class DefaultStreamingPipeline:
    StreamingPipeline,
    Sendable {

    private let cacheWarmer:
        MediaCacheWarmer

    private let offlineController:
        OfflineDownloadController

    private let cdnSelector:
        CdnSelector?

    private let cacheKeyFactory:
        MediaCacheKeyProviding

    private let codecNegotiator:
        StreamingCodecNegotiator

    public init(
        cdns: [Cdn] = [],
        cacheWarmer:
            MediaCacheWarmer,
        offlineController:
            OfflineDownloadController =
            OfflineDownloadController(),
        measurer:
            LatencyMeasurer =
            DefaultLatencyMeasurer(),
        cacheKeyFactory:
            MediaCacheKeyProviding =
            DefaultMediaCacheKeyFactory(),
        codecNegotiator:
            StreamingCodecNegotiator =
            StreamingCodecNegotiator()
    ) {
        self.cacheWarmer =
            cacheWarmer

        self.offlineController =
            offlineController

        self.cdnSelector =
            cdns.isEmpty
            ? nil
            : CdnSelector(
                cdns: cdns,
                measurer: measurer
            )

        self.cacheKeyFactory =
            cacheKeyFactory

        self.codecNegotiator =
            codecNegotiator
    }

    public func warm(
        mediaId: String,
        source: MediaSource,
        priority: WarmPriority
    ) async {

        guard !Task.isCancelled else {
            return
        }

        // IMPORTANT:
        // Compute the cache identity from the logical/original source,
        // not the CDN-resolved URL. Otherwise every CDN creates a distinct
        // local cache namespace for the same logical media.
        let cacheKey =
            cacheKeyFactory.makeKey(
                mediaId:
                    mediaId,
                source:
                    source
            )

        // Use the negotiated variant for warming too, but keep the cache key
        // tied to the original logical media identity above.
        let negotiatedSource = codecNegotiator.negotiate(source)

        var networkSource =
            negotiatedSource

        if let selector =
            cdnSelector,
           let best =
            await selector.selectBestCdn(
                forPath:
                    negotiatedSource.url.path
            ) {

            // Replace only the network authority. Keep the negotiated
            // codec query, auth query items, fragment and original path.
            if var resolvedComponents = URLComponents(
                url: negotiatedSource.url,
                resolvingAgainstBaseURL: false
            ),
               let cdnComponents = URLComponents(
                url: best.baseURL,
                resolvingAgainstBaseURL: false
               ) {
                resolvedComponents.scheme = cdnComponents.scheme ?? resolvedComponents.scheme
                resolvedComponents.host = cdnComponents.host ?? resolvedComponents.host
                resolvedComponents.port = cdnComponents.port
                resolvedComponents.user = cdnComponents.user
                resolvedComponents.password = cdnComponents.password

                if let resolved = resolvedComponents.url {
                    networkSource = MediaSource(
                        url: resolved,
                        type: negotiatedSource.type,
                        headers: negotiatedSource.headers,
                        metadata: negotiatedSource.metadata
                    )
                }
            }
        }

        _ = await cacheWarmer.warm(
            MediaCacheWarmRequest(
                mediaId:
                    mediaId,
                source:
                    networkSource,
                cacheKey:
                    cacheKey,
                priority:
                    priority
            )
        )
    }
}
