import Foundation

/// A rendition ceiling expressed in pixels, matching Android Media3's
/// TrackSelectionParameters.setMaxVideoSize(width:height:) behavior.
public struct VideoResolution: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
    }
}

/// Initial adaptive-streaming constraints selected for one playback request.
/// A nil value means AVFoundation may choose without that particular ceiling.
public struct PlaybackQualityPreferences: Equatable, Sendable {
    public let maximumResolution: VideoResolution?
    public let maximumPeakBitrateBps: Double?

    public init(
        maximumResolution: VideoResolution? = nil,
        maximumPeakBitrateBps: Double? = nil
    ) {
        self.maximumResolution = maximumResolution
        self.maximumPeakBitrateBps = maximumPeakBitrateBps.flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        }
    }

    public static let unrestricted = PlaybackQualityPreferences()
}

/// Mirrors Android's recommendation-aware starting rendition and thermal cap.
/// AVFoundation remains responsible for ABR: these are upper bounds, not
/// requests to select a fixed variant.
public struct PlaybackQualityPolicy: Sendable {
    public init() {}

    public func preferences(
        matchScore: Double,
        thermalState: PlayerPoolEnvironment.ThermalState
    ) -> PlaybackQualityPreferences {
        let normalizedScore = matchScore.isFinite
            ? min(max(matchScore, 0), 1)
            : 0.5

        let maximumResolution: VideoResolution?
        if normalizedScore > 0.9 {
            maximumResolution = VideoResolution(width: 1920, height: 1080)
        } else if normalizedScore < 0.4 {
            maximumResolution = VideoResolution(width: 640, height: 360)
        } else {
            maximumResolution = nil
        }

        // Android starts constraining rendition bitrate at MODERATE thermal
        // state. On iOS, FAIR is the first non-nominal ProcessInfo thermal tier.
        let thermalBitrateCeiling = thermalState == .nominal
            ? nil
            : 2_000_000.0

        return PlaybackQualityPreferences(
            maximumResolution: maximumResolution,
            maximumPeakBitrateBps: thermalBitrateCeiling
        )
    }
}
