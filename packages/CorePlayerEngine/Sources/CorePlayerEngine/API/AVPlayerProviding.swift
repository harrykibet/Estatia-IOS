//
//  AVPlayerProviding.swift
//  CorePlayerEngine
//
//  Presentation bridge for native AVKit/SwiftUI surfaces.
//

import AVFoundation

/// Exposes the AVPlayer owned by an AVFoundation-backed engine for native
/// video rendering. Playback commands and state remain owned by PlayerEngine.
@MainActor
public protocol AVPlayerProviding: AnyObject {
    var presentationPlayer: AVPlayer? { get }
}
