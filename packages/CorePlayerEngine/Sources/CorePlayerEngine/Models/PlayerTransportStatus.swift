import Foundation

/// Transport state reported by AVPlayer, distinct from a playback command.
///
/// The playback actor changes its authoritative state only after receiving
/// one of these observed values.
enum PlayerTransportStatus: Sendable {
    case paused
    case waiting
    case playing
}
