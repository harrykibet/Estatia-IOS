import Foundation

/// Builds the H.264 Baseline manifest URL used after a decoder-specific
/// failure on an Estatia-hosted media source.
enum CodecBaselineFallbackPolicy {
    static func fallbackSource(for source: MediaSource) -> MediaSource? {
        guard isInternalMediaHost(source.url.host),
              var components = URLComponents(
                url: source.url,
                resolvingAgainstBaseURL: false
              )
        else {
            return nil
        }

        let queryItems = components.queryItems ?? []
        let codecValues = queryItems
            .filter { $0.name.caseInsensitiveCompare("codec") == .orderedSame }
            .compactMap(\.value)

        guard !codecValues.contains(where: {
            $0.caseInsensitiveCompare("baseline") == .orderedSame
        }) else {
            return nil
        }

        // Replace all codec values so malformed/duplicated query parameters
        // cannot cause the backend to select an ambiguous rendition.
        var updatedQueryItems = queryItems.filter {
            $0.name.caseInsensitiveCompare("codec") != .orderedSame
        }
        updatedQueryItems.append(
            URLQueryItem(name: "codec", value: "baseline")
        )
        components.queryItems = updatedQueryItems

        guard let fallbackURL = components.url else {
            return nil
        }

        return MediaSource(
            url: fallbackURL,
            type: source.type,
            headers: source.headers,
            metadata: source.metadata
        )
    }

    private static func isInternalMediaHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "estatia.com" || host.hasSuffix(".estatia.com")
    }
}
