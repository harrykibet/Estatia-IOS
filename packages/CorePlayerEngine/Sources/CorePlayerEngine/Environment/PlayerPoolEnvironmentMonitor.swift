import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Publishes resource-environment changes that can safely influence player
/// pool capacity. All callbacks are delivered on the main actor.
@MainActor
final class PlayerPoolEnvironmentMonitor {
    private var observers: [NSObjectProtocol] = []
    private var memoryPressure: PlayerPoolEnvironment.MemoryPressure = .normal
    private var onChange: (@MainActor @Sendable (PlayerPoolEnvironment) -> Void)?

    func start(
        onChange: @escaping @MainActor @Sendable (PlayerPoolEnvironment) -> Void
    ) {
        stop()
        self.onChange = onChange

        observe(ProcessInfo.thermalStateDidChangeNotification)
        observe(Notification.Name("NSProcessInfoPowerStateDidChangeNotification"))

        #if canImport(UIKit)
        observe(UIApplication.didEnterBackgroundNotification)
        observe(UIApplication.willEnterForegroundNotification)
        observe(UIApplication.didReceiveMemoryWarningNotification)
        #endif

        publish()
    }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        onChange = nil
    }

    private func observe(_ name: Notification.Name) {
        let token = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handle(notification)
            }
        }
        observers.append(token)
    }

    private func handle(_ notification: Notification) {
        #if canImport(UIKit)
        if notification.name == UIApplication.didReceiveMemoryWarningNotification {
            memoryPressure = .warning
        } else if notification.name == UIApplication.willEnterForegroundNotification {
            // A foreground transition is a fresh opportunity to re-evaluate
            // the current process conditions after the OS warning.
            memoryPressure = .normal
        }
        #endif

        publish()
    }

    private func publish() {
        guard let onChange else { return }

        let processInfo = ProcessInfo.processInfo
        let thermalState: PlayerPoolEnvironment.ThermalState

        switch processInfo.thermalState {
        case .nominal:
            thermalState = .nominal
        case .fair:
            thermalState = .fair
        case .serious:
            thermalState = .serious
        case .critical:
            thermalState = .critical
        @unknown default:
            thermalState = .serious
        }

        #if canImport(UIKit)
        let isAppVisible = UIApplication.shared.applicationState == .active
        #else
        let isAppVisible = true
        #endif

        let physicalMemoryMB = Int(
            min(
                processInfo.physicalMemory / (1_024 * 1_024),
                UInt64(Int.max)
            )
        )

        onChange(
            PlayerPoolEnvironment(
                physicalMemoryMB: physicalMemoryMB,
                thermalState: thermalState,
                isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
                isAppVisible: isAppVisible,
                memoryPressure: memoryPressure
            )
        )
    }
}
