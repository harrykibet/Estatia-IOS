import Foundation

/// A platform-neutral snapshot of the resource conditions that affect video
/// decoder and player-instance capacity.
public struct PlayerPoolEnvironment: Equatable, Sendable {
    public enum ThermalState: Int, Equatable, Sendable {
        case nominal
        case fair
        case serious
        case critical
    }

    public enum MemoryPressure: Equatable, Sendable {
        case normal
        case warning
    }

    public let physicalMemoryMB: Int
    public let thermalState: ThermalState
    public let isLowPowerModeEnabled: Bool
    public let isAppVisible: Bool
    public let memoryPressure: MemoryPressure

    public init(
        physicalMemoryMB: Int,
        thermalState: ThermalState = .nominal,
        isLowPowerModeEnabled: Bool = false,
        isAppVisible: Bool = true,
        memoryPressure: MemoryPressure = .normal
    ) {
        self.physicalMemoryMB = max(0, physicalMemoryMB)
        self.thermalState = thermalState
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.isAppVisible = isAppVisible
        self.memoryPressure = memoryPressure
    }
}

/// Calculates a conservative player-pool ceiling from device and runtime state.
///
/// iOS does not expose Android's `MediaCodecInfo.maxSupportedInstances`
/// equivalent or a reliable public count of simultaneous hardware video
/// decoders. This policy therefore uses total physical memory and runtime
/// pressure signals, while keeping the configured pool maximum as a hard cap.
public struct PlayerPoolSizingPolicy: Sendable {
    public init() {}

    public func calculateMaxPlayers(
        environment: PlayerPoolEnvironment,
        configuredMaximum: Int
    ) -> Int {
        let hardMaximum = max(1, configuredMaximum)

        if !environment.isAppVisible ||
            environment.isLowPowerModeEnabled ||
            environment.thermalState == .critical ||
            environment.memoryPressure == .warning {
            return 1
        }

        let deviceCapacity: Int
        switch environment.physicalMemoryMB {
        case ..<3_072:
            deviceCapacity = 1
        case ..<4_608:
            deviceCapacity = 2
        case ..<6_144:
            deviceCapacity = 3
        default:
            deviceCapacity = 4
        }

        var target = min(deviceCapacity, hardMaximum)

        switch environment.thermalState {
        case .nominal:
            break
        case .fair:
            target = max(1, target - 1)
        case .serious, .critical:
            target = 1
        }

        return max(1, target)
    }
}
