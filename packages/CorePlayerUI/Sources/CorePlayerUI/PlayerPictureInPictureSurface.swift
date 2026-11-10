#if os(iOS)
import AVKit
import SwiftUI
import UIKit

/// Presents the engine-owned AVPlayer through AVKit so iOS can transition the
/// inline video into Picture in Picture when the user backgrounds the app.
///
/// The representable never creates or commands a player. It only supplies the
/// exact AVPlayer exposed by AVPlayerProviding to AVPlayerViewController.
struct PlayerPictureInPictureSurface: UIViewControllerRepresentable {
    let player: AVPlayer
    let shouldAutoStartPictureInPicture: Bool
    let onPictureInPictureChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPictureInPictureChanged: onPictureInPictureChanged)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline =
            shouldAutoStartPictureInPicture && AVPictureInPictureController.isPictureInPictureSupported()
        // PlayerManager owns Now Playing metadata and remote commands.
        controller.updatesNowPlayingInfoCenter = false
        controller.videoGravity = .resizeAspect
        controller.view.backgroundColor = .black
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(
        _ controller: AVPlayerViewController,
        context: Context
    ) {
        context.coordinator.onPictureInPictureChanged = onPictureInPictureChanged
        if controller.player !== player {
            controller.player = player
        }
        controller.canStartPictureInPictureAutomaticallyFromInline =
            shouldAutoStartPictureInPicture && AVPictureInPictureController.isPictureInPictureSupported()
    }

    static func dismantleUIViewController(
        _ controller: AVPlayerViewController,
        coordinator: Coordinator
    ) {
        // A PiP controller may outlive the inline SwiftUI cell. Do not detach
        // the engine-owned player or delegate while PiP remains active.
        guard !coordinator.isPictureInPictureActive else { return }
        controller.delegate = nil
        controller.player = nil
    }

    @MainActor
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var onPictureInPictureChanged: (Bool) -> Void
        private(set) var isPictureInPictureActive = false

        init(onPictureInPictureChanged: @escaping (Bool) -> Void) {
            self.onPictureInPictureChanged = onPictureInPictureChanged
        }

        func playerViewControllerWillStartPictureInPicture(
            _ playerViewController: AVPlayerViewController
        ) {
            isPictureInPictureActive = true
            PlayerPictureInPictureRegistry.shared.retain(
                controller: playerViewController,
                coordinator: self
            )
            onPictureInPictureChanged(true)
        }

        func playerViewControllerDidStartPictureInPicture(
            _ playerViewController: AVPlayerViewController
        ) {
            isPictureInPictureActive = true
            PlayerPictureInPictureRegistry.shared.retain(
                controller: playerViewController,
                coordinator: self
            )
            onPictureInPictureChanged(true)
        }

        func playerViewControllerDidStopPictureInPicture(
            _ playerViewController: AVPlayerViewController
        ) {
            isPictureInPictureActive = false
            onPictureInPictureChanged(false)
            PlayerPictureInPictureRegistry.shared.release()
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            failedToStartPictureInPictureWithError error: Error
        ) {
            isPictureInPictureActive = false
            onPictureInPictureChanged(false)
            PlayerPictureInPictureRegistry.shared.release()
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
        ) {
            // The feed remains the owning presentation surface. There is no
            // second player or route to reconstruct when PiP returns inline.
            completionHandler(true)
        }
    }
}

/// AVKit can keep PiP running after the SwiftUI feed cell is dismantled.
/// Retaining the active controller and delegate keeps lifecycle callbacks alive
/// until PiP actually stops; only one PiP video can be active per application.
@MainActor
private final class PlayerPictureInPictureRegistry {
    static let shared = PlayerPictureInPictureRegistry()

    private var controller: AVPlayerViewController?
    private var coordinator: PlayerPictureInPictureSurface.Coordinator?

    func retain(
        controller: AVPlayerViewController,
        coordinator: PlayerPictureInPictureSurface.Coordinator
    ) {
        self.controller = controller
        self.coordinator = coordinator
    }

    func release() {
        controller?.delegate = nil
        controller?.player = nil
        controller = nil
        coordinator = nil
    }
}
#endif
