import CoreMedia
import Foundation
import VideoToolbox

/// Hardware decode capabilities the Estatia media backend understands.
public struct StreamCodecCapabilities: Sendable, Equatable {
    public let supportsAV1: Bool
    public let supportsHEVC: Bool
    public let supportsDolbyVision: Bool

    public init(
        supportsAV1: Bool,
        supportsHEVC: Bool,
        supportsDolbyVision: Bool
    ) {
        self.supportsAV1 = supportsAV1
        self.supportsHEVC = supportsHEVC
        self.supportsDolbyVision = supportsDolbyVision
    }

    /// The backend's documented capability names, in deterministic order.
    public var requestHeaderValue: String {
        [
            supportsAV1 ? "av1" : nil,
            supportsHEVC ? "hevc" : nil,
            supportsDolbyVision ? "dolbyvision" : nil
        ]
        .compactMap { $0 }
        .joined(separator: ",")
    }

    /// Mirrors Android's AV1-first, then HEVC manifest selection.
    public var preferredCodec: String? {
        if supportsAV1 { return "av1" }
        if supportsHEVC { return "hevc" }
        return nil
    }

    /// Conservatively advertises only codecs VideoToolbox confirms can be
    /// hardware-decoded by the current system.
    public static var currentSystem: StreamCodecCapabilities {
        // AV1 hardware decoding is available only on newer Apple OS versions.
        // Keep the package's macOS 13 deployment target safe by treating it
        // as unsupported there rather than invoking a newer codec constant.
        let supportsAV1: Bool
        if #available(iOS 17.0, macOS 14.0, *) {
            supportsAV1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        } else {
            supportsAV1 = false
        }

        return StreamCodecCapabilities(
            supportsAV1: supportsAV1,
            supportsHEVC: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
            supportsDolbyVision: VTIsHardwareDecodeSupported(kCMVideoCodecType_DolbyVisionHEVC)
        )
    }
}

/// Adds the platform's codec capabilities to internal Estatia media requests.
///
/// Only `estatia.com` media hosts are negotiated. External media URLs retain
/// their original URL and headers. A caller-supplied codec query or capability
/// header is respected rather than silently overwritten.
public struct StreamingCodecNegotiator: Sendable {
    private let capabilities: StreamCodecCapabilities

    public init(
        capabilities: StreamCodecCapabilities = .currentSystem
    ) {
        self.capabilities = capabilities
    }

    public func negotiate(_ source: MediaSource) -> MediaSource {
        guard Self.isInternalMediaHost(source.url.host) else {
            return source
        }

        var headers = source.headers ?? [:]
        let hasCallerCapabilities = headers.keys.contains {
            $0.caseInsensitiveCompare("X-Estatia-Capabilities") == .orderedSame
        }

        if !hasCallerCapabilities && !capabilities.requestHeaderValue.isEmpty {
            headers["X-Estatia-Capabilities"] = capabilities.requestHeaderValue
        }

        var resolvedURL = source.url
        if let preferredCodec = capabilities.preferredCodec,
           var components = URLComponents(
               url: source.url,
               resolvingAgainstBaseURL: false
           ) {
            let hasExplicitCodec = components.queryItems?.contains {
                $0.name.caseInsensitiveCompare("codec") == .orderedSame
            } ?? false

            if !hasExplicitCodec {
                var queryItems = components.queryItems ?? []
                queryItems.append(
                    URLQueryItem(name: "codec", value: preferredCodec)
                )
                components.queryItems = queryItems
                resolvedURL = components.url ?? source.url
            }
        }

        return MediaSource(
            url: resolvedURL,
            type: source.type,
            headers: headers.isEmpty ? nil : headers,
            metadata: source.metadata
        )
    }

    private static func isInternalMediaHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "estatia.com" || host.hasSuffix(".estatia.com")
    }
}
