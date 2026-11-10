import Foundation

#if canImport(AVFoundation) && os(iOS)
import AVFoundation
#endif

/// Owns AVAudioSession activation and observes system interruptions and
/// output-route changes. Playback policy remains in PlayerManager.
@MainActor
final class AudioSessionManager {
    private let notificationCenter: NotificationCenter

    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

    private var onInterruptionBegan: (() -> Void)?
    private var onInterruptionEnded: ((Bool) -> Void)?
    private var onRouteBecameNoisy: (() -> Void)?

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    func startObserving(
        onInterruptionBegan: @escaping () -> Void,
        onInterruptionEnded: @escaping (Bool) -> Void,
        onRouteBecameNoisy: @escaping () -> Void
    ) {
        stopObserving()

        self.onInterruptionBegan = onInterruptionBegan
        self.onInterruptionEnded = onInterruptionEnded
        self.onRouteBecameNoisy = onRouteBecameNoisy

        #if canImport(AVFoundation) && os(iOS)
        interruptionObserver = notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            // Notification is not Sendable. Read its primitive payload on the
            // observer callback before entering the main-actor-isolated code.
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated {
                self?.handleInterruption(
                    typeRawValue: rawType,
                    optionsRawValue: rawOptions
                )
            }
        }

        routeChangeObserver = notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            // Only transfer the Sendable raw reason across the actor boundary.
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleRouteChange(reasonRawValue: rawReason)
            }
        }
        #endif
    }

    func request() {
        #if canImport(AVFoundation) && os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
        } catch {
            NSLog("[AudioSessionManager] Audio-session activation failed: %@", String(describing: error))
        }
        #endif
    }

    func abandon() {
        #if canImport(AVFoundation) && os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        } catch {
            NSLog("[AudioSessionManager] Audio-session deactivation failed: %@", String(describing: error))
        }
        #endif
    }

    func cleanup() {
        stopObserving()
        abandon()
    }

    private func stopObserving() {
        if let interruptionObserver {
            notificationCenter.removeObserver(interruptionObserver)
        }
        if let routeChangeObserver {
            notificationCenter.removeObserver(routeChangeObserver)
        }
        interruptionObserver = nil
        routeChangeObserver = nil
        onInterruptionBegan = nil
        onInterruptionEnded = nil
        onRouteBecameNoisy = nil
    }

    #if canImport(AVFoundation) && os(iOS)
    private func handleInterruption(
        typeRawValue: UInt?,
        optionsRawValue: UInt
    ) {
        guard let typeRawValue,
              let type = AVAudioSession.InterruptionType(rawValue: typeRawValue)
        else {
            return
        }

        switch type {
        case .began:
            onInterruptionBegan?()
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRawValue)
            onInterruptionEnded?(options.contains(.shouldResume))
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reasonRawValue: UInt?) {
        guard let reasonRawValue,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRawValue)
        else {
            return
        }

        // The old output route became unavailable (for example, wired or
        // Bluetooth headphones were disconnected). Do not resume implicitly.
        if reason == .oldDeviceUnavailable {
            onRouteBecameNoisy?()
        }
    }
    #endif
}
