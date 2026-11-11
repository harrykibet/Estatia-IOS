import Foundation
import CorePlayerEngine

#if canImport(UIKit)
import UIKit
#endif

/// Bridges UIKit background URLSession wake-ups to the engine-owned
/// progressive and HLS download sessions.
@MainActor
public enum PlayerBackgroundSessionEvents {
    public static func handle(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        PlayerManager.shared.handleBackgroundSessionEvents(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }
}
